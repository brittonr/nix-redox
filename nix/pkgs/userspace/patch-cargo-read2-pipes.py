#!/usr/bin/env python3
"""
Patch cargo-util's read2() to avoid poll() on Redox.

cargo-util has its OWN read2() function (separate from std's) that uses
libc::poll() to multiplex reading stdout/stderr from child processes.
This is used by cargo's exec_with_streaming() for build script output capture.

On Redox, poll() (implemented via epoll → /scheme/event) doesn't reliably
deliver events for pipe fds after fork+exec. This causes build scripts to
appear to hang: the build script writes to its stdout pipe, but the parent
(cargo) never sees the poll event and never reads the data, so the pipe
fills up and the child's write blocks.

Fix: On Redox, read sequentially (stdout first, then stderr) instead of
using poll() to multiplex. This is less efficient but correct, and build
scripts typically produce small amounts of output.

Target file: src/tools/cargo/crates/cargo-util/src/read2.rs
"""

import sys
import os

def patch_file(path):
    with open(path, 'r') as f:
        content = f.read()

    original = content

    # The unix implementation uses libc::poll for multiplexing.
    # We need to add a Redox-specific path that reads sequentially.
    #
    # The function signature is:
    #   pub fn read2(
    #       mut out_pipe: ChildStdout,
    #       mut err_pipe: ChildStderr,
    #       data: &mut dyn FnMut(bool, &mut Vec<u8>, bool),
    #   ) -> io::Result<()>

    old = '''#[cfg(unix)]
mod imp {
    use libc::{F_GETFL, F_SETFL, O_NONBLOCK, c_int, fcntl};
    use std::io;
    use std::io::prelude::*;
    use std::mem;
    use std::os::unix::prelude::*;
    use std::process::{ChildStderr, ChildStdout};

    fn set_nonblock(fd: c_int) -> io::Result<()> {
        let flags = unsafe { fcntl(fd, F_GETFL) };
        if flags == -1 || unsafe { fcntl(fd, F_SETFL, flags | O_NONBLOCK) } == -1 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    pub fn read2(
        mut out_pipe: ChildStdout,
        mut err_pipe: ChildStderr,
        data: &mut dyn FnMut(bool, &mut Vec<u8>, bool),
    ) -> io::Result<()> {
        set_nonblock(out_pipe.as_raw_fd())?;
        set_nonblock(err_pipe.as_raw_fd())?;

        let mut out_done = false;
        let mut err_done = false;
        let mut out = Vec::new();
        let mut err = Vec::new();

        let mut fds: [libc::pollfd; 2] = unsafe { mem::zeroed() };
        fds[0].fd = out_pipe.as_raw_fd();
        fds[0].events = libc::POLLIN;
        fds[1].fd = err_pipe.as_raw_fd();
        fds[1].events = libc::POLLIN;
        let mut nfds = 2;
        let mut errfd = 1;

        while nfds > 0 {
            // wait for either pipe to become readable using `poll`
            let r = unsafe { libc::poll(fds.as_mut_ptr(), nfds, -1) };
            if r == -1 {
                let err = io::Error::last_os_error();
                if err.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(err);
            }

            // Read as much as we can from each pipe, ignoring EWOULDBLOCK or
            // EAGAIN. If we hit EOF, then this will happen because the underlying
            // reader will return Ok(0), in which case we'll see `Ok` ourselves. In
            // this case we flip the other fd back into blocking mode and read
            // whatever's leftover on that file descriptor.
            let handle = |res: io::Result<_>| match res {
                Ok(_) => Ok(true),
                Err(e) => {
                    if e.kind() == io::ErrorKind::WouldBlock {
                        Ok(false)
                    } else {
                        Err(e)
                    }
                }
            };
            if !err_done && fds[errfd].revents != 0 && handle(err_pipe.read_to_end(&mut err))? {
                err_done = true;
                nfds -= 1;
            }
            data(false, &mut err, err_done);
            if !out_done && fds[0].revents != 0 && handle(out_pipe.read_to_end(&mut out))? {
                out_done = true;
                fds[0].fd = err_pipe.as_raw_fd();
                errfd = 0;
                nfds -= 1;
            }
            data(true, &mut out, out_done);
        }
        Ok(())
    }
}'''

    new = '''#[cfg(unix)]
mod imp {
    use std::io;
    use std::io::prelude::*;
    use std::process::{ChildStderr, ChildStdout};
    use std::thread;

    pub fn read2(
        mut out_pipe: ChildStdout,
        mut err_pipe: ChildStderr,
        data: &mut dyn FnMut(bool, &mut Vec<u8>, bool),
    ) -> io::Result<()> {
        // REDOX PATCH: On Redox, poll() on pipes after fork+exec doesn't
        // reliably deliver events, causing build scripts to hang.
        //
        // Use a background thread for stderr to avoid the classic pipe
        // deadlock: if the child writes >64KB to stderr before closing
        // stdout, a sequential read would deadlock (parent blocks on
        // stdout read_to_end, child blocks on stderr write because
        // buffer is full and nobody is reading).
        //
        // Thread-based approach: read stderr in a background thread while
        // the main thread reads stdout. Both can make progress independently.
        let err_handle = thread::spawn(move || -> io::Result<Vec<u8>> {
            let mut err = Vec::new();
            err_pipe.read_to_end(&mut err)?;
            Ok(err)
        });

        let mut out = Vec::new();
        out_pipe.read_to_end(&mut out)?;
        data(true, &mut out, true);

        let mut err = err_handle.join().expect("stderr reader thread panicked")?;
        data(false, &mut err, true);

        Ok(())
    }
}'''

    if old in content:
        content = content.replace(old, new)
        print(f"  Patched: cargo-util read2() poll → sequential reads")
    else:
        print(f"  WARNING: cargo-util read2() pattern not found in {path}")
        # Try to find approximate match
        if 'libc::poll' in content:
            print(f"    (libc::poll exists but exact pattern differs)")
        if 'fn read2' in content:
            print(f"    (fn read2 exists)")
        return False

    if content != original:
        with open(path, 'w') as f:
            f.write(content)
        return True
    return False

def main():
    if len(sys.argv) < 2:
        print("Usage: patch-cargo-read2-pipes.py <rust-source-dir>")
        sys.exit(1)

    src_dir = sys.argv[1]
    target = os.path.join(src_dir, 'src', 'tools', 'cargo', 'crates', 'cargo-util', 'src', 'read2.rs')

    if not os.path.exists(target):
        print(f"ERROR: {target} not found")
        sys.exit(1)

    print(f"Patching {target}...")
    if patch_file(target):
        print("Done! cargo-util read2() will use sequential reads.")
    else:
        print("WARNING: Patch failed!")
        sys.exit(1)

if __name__ == '__main__':
    main()
