#!/usr/bin/env python3
"""
Patch Rust std's read2() to avoid poll() on Redox.

read2() uses poll() to multiplex reading from two pipes (stdout + stderr).
On Redox, poll() on pipes crashes. Fix: on Redox, read sequentially instead
of using poll(). This is less efficient but correct.

Target file: library/std/src/sys/pal/unix/pipe.rs
"""

import sys
import os

def patch_file(path):
    with open(path, 'r') as f:
        content = f.read()

    original = content

    # Suppress unused import warnings for items only used in the poll() path.
    # On Redox, the poll path is cfg'd out, making mem and cvt_r unused.
    for imp in ['use crate::mem;', 'use crate::sys::{cvt, cvt_r};']:
        if imp in content:
            content = content.replace(imp, '#[allow(unused_imports)]\n' + imp, 1)
    print(f"  Added allow(unused_imports) to pipe.rs imports")

    # Match the entire read2 function including the inner read() helper
    old = '''pub fn read2(p1: AnonPipe, v1: &mut Vec<u8>, p2: AnonPipe, v2: &mut Vec<u8>) -> io::Result<()> {
    // Set both pipes into nonblocking mode as we're gonna be reading from both
    // in the `select` loop below, and we wouldn't want one to block the other!
    let p1 = p1.into_inner();
    let p2 = p2.into_inner();
    p1.set_nonblocking(true)?;
    p2.set_nonblocking(true)?;

    let mut fds: [libc::pollfd; 2] = unsafe { mem::zeroed() };
    fds[0].fd = p1.as_raw_fd();
    fds[0].events = libc::POLLIN;
    fds[1].fd = p2.as_raw_fd();
    fds[1].events = libc::POLLIN;
    loop {
        // wait for either pipe to become readable using `poll`
        cvt_r(|| unsafe { libc::poll(fds.as_mut_ptr(), 2, -1) })?;

        if fds[0].revents != 0 && read(&p1, v1)? {
            p2.set_nonblocking(false)?;
            return p2.read_to_end(v2).map(drop);
        }
        if fds[1].revents != 0 && read(&p2, v2)? {
            p1.set_nonblocking(false)?;
            return p1.read_to_end(v1).map(drop);
        }
    }

    // Read as much as we can from each pipe, ignoring EWOULDBLOCK or
    // EAGAIN. If we hit EOF, then this will happen because the underlying
    // reader will return Ok(0), in which case we'll see `Ok` ourselves. In
    // this case we flip the other fd back into blocking mode and read
    // whatever's leftover on that file descriptor.
    fn read(fd: &FileDesc, dst: &mut Vec<u8>) -> Result<bool, io::Error> {
        match fd.read_to_end(dst) {
            Ok(_) => Ok(true),
            Err(e) => {
                if e.raw_os_error() == Some(libc::EWOULDBLOCK)
                    || e.raw_os_error() == Some(libc::EAGAIN)
                {
                    Ok(false)
                } else {
                    Err(e)
                }
            }
        }
    }
}'''

    new = '''#[allow(unused_imports, dead_code)]
pub fn read2(p1: AnonPipe, v1: &mut Vec<u8>, p2: AnonPipe, v2: &mut Vec<u8>) -> io::Result<()> {
    // REDOX PATCH: On Redox, poll() on pipes crashes (Invalid opcode).
    // Use a thread-based approach to avoid both poll() and the classic
    // sequential-read pipe deadlock (child writes >64KB to one pipe,
    // blocks, parent blocks reading the other pipe → deadlock).
    #[cfg(target_os = "redox")]
    {
        use crate::thread;
        let p1 = p1.into_inner();
        let p2 = p2.into_inner();
        // Read p2 (stderr) in background thread
        let handle = thread::spawn(move || -> io::Result<Vec<u8>> {
            let mut buf = Vec::new();
            p2.read_to_end(&mut buf)?;
            Ok(buf)
        });
        // Read p1 (stdout) in main thread
        p1.read_to_end(v1)?;
        // Join stderr thread
        let stderr_data = handle.join().expect("stderr reader panicked")?;
        v2.extend_from_slice(&stderr_data);
        return Ok(());
    }

    #[cfg(not(target_os = "redox"))]
    {
    // Set both pipes into nonblocking mode as we're gonna be reading from both
    // in the `select` loop below, and we wouldn't want one to block the other!
    let p1 = p1.into_inner();
    let p2 = p2.into_inner();
    p1.set_nonblocking(true)?;
    p2.set_nonblocking(true)?;

    let mut fds: [libc::pollfd; 2] = unsafe { mem::zeroed() };
    fds[0].fd = p1.as_raw_fd();
    fds[0].events = libc::POLLIN;
    fds[1].fd = p2.as_raw_fd();
    fds[1].events = libc::POLLIN;
    loop {
        // wait for either pipe to become readable using `poll`
        cvt_r(|| unsafe { libc::poll(fds.as_mut_ptr(), 2, -1) })?;

        if fds[0].revents != 0 && read(&p1, v1)? {
            p2.set_nonblocking(false)?;
            return p2.read_to_end(v2).map(drop);
        }
        if fds[1].revents != 0 && read(&p2, v2)? {
            p1.set_nonblocking(false)?;
            return p1.read_to_end(v1).map(drop);
        }
    }

    // Read as much as we can from each pipe, ignoring EWOULDBLOCK or
    // EAGAIN. If we hit EOF, then this will happen because the underlying
    // reader will return Ok(0), in which case we'll see `Ok` ourselves. In
    // this case we flip the other fd back into blocking mode and read
    // whatever's leftover on that file descriptor.
    fn read(fd: &FileDesc, dst: &mut Vec<u8>) -> Result<bool, io::Error> {
        match fd.read_to_end(dst) {
            Ok(_) => Ok(true),
            Err(e) => {
                if e.raw_os_error() == Some(libc::EWOULDBLOCK)
                    || e.raw_os_error() == Some(libc::EAGAIN)
                {
                    Ok(false)
                } else {
                    Err(e)
                }
            }
        }
    }
    }
}'''

    if old in content:
        content = content.replace(old, new)
        print(f"  Patched: read2() poll → sequential on Redox")
    else:
        print(f"  WARNING: read2() pattern not found")
        return False

    with open(path, 'w') as f:
        f.write(content)
    return True

def main():
    if len(sys.argv) < 2:
        print("Usage: patch-rustc-read2-pipes.py <rust-source-dir>")
        sys.exit(1)

    src_dir = sys.argv[1]
    target = os.path.join(src_dir, 'library', 'std', 'src', 'sys', 'pal', 'unix', 'pipe.rs')

    if not os.path.exists(target):
        print(f"ERROR: {target} not found")
        sys.exit(1)

    print(f"Patching {target}...")
    if patch_file(target):
        print("Done! read2() will use sequential reads on Redox.")
    else:
        print("WARNING: Patch failed!")
        sys.exit(1)

if __name__ == '__main__':
    main()
