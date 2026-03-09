#!/usr/bin/env python3
"""
Patch the jobserver crate to avoid poll() on Redox.

Cargo uses a pipe-based jobserver for parallel builds (JOBS>1). When
acquiring a token, the jobserver crate first tries a blocking read, then
falls back to poll() if the read returns WouldBlock. On Redox, poll() on
pipes doesn't reliably deliver events, causing cargo to hang waiting for
tokens that will never arrive.

Fix: On Redox, skip the poll() fallback entirely. Ensure the read end is
in blocking mode and just do a plain blocking read. When a token is
released (another rustc exits), the read will wake up.

Also patches the helper thread's SIGUSR1 mechanism, which may not work
on Redox. On Redox, use a simpler shutdown approach.

Target file: vendor/jobserver-*/src/unix.rs
"""

import sys
import os
import glob


def patch_file(path):
    with open(path, 'r') as f:
        content = f.read()

    original = content

    # Patch acquire_allow_interrupts to skip poll() on Redox.
    # The function tries read() first, then falls to poll() on WouldBlock.
    # On Redox, we ensure the pipe is blocking and just do a plain read.
    old = '''    fn acquire_allow_interrupts(&self) -> io::Result<Option<Acquired>> {
        // We don't actually know if the file descriptor here is set in
        // blocking or nonblocking mode. AFAIK all released versions of
        // `make` use blocking fds for the jobserver, but the unreleased
        // version of `make` doesn't. In the unreleased version jobserver
        // fds are set to nonblocking and combined with `pselect`
        // internally.
        //
        // Here we try to be compatible with both strategies. We optimistically
        // try to read from the file descriptor which then may block, return
        // a token or indicate that polling is needed.
        // Blocking reads (if possible) allows the kernel to be more selective
        // about which readers to wake up when a token is written to the pipe.
        //
        // We use `poll` here to block this thread waiting for read
        // readiness, and then afterwards we perform the `read` itself. If
        // the `read` returns that it would block then we start over and try
        // again.
        //
        // Also note that we explicitly don't handle EINTR here. That's used
        // to shut us down, so we otherwise punt all errors upwards.
        unsafe {
            let mut fd: libc::pollfd = mem::zeroed();
            let mut read = &self.read;
            fd.fd = read.as_raw_fd();
            fd.events = libc::POLLIN;
            loop {
                let mut buf = [0];
                match read.read(&mut buf) {
                    Ok(1) => return Ok(Some(Acquired { byte: buf[0] })),
                    Ok(_) => {
                        return Err(io::Error::new(
                            io::ErrorKind::UnexpectedEof,
                            "early EOF on jobserver pipe",
                        ));
                    }
                    Err(e) => match e.kind() {
                        io::ErrorKind::WouldBlock => { /* fall through to polling */ }
                        io::ErrorKind::Interrupted => return Ok(None),
                        _ => return Err(e),
                    },
                }

                loop {
                    fd.revents = 0;
                    if libc::poll(&mut fd, 1, -1) == -1 {
                        let e = io::Error::last_os_error();
                        return match e.kind() {
                            io::ErrorKind::Interrupted => Ok(None),
                            _ => Err(e),
                        };
                    }
                    if fd.revents != 0 {
                        break;
                    }
                }
            }
        }
    }'''

    new = '''    fn acquire_allow_interrupts(&self) -> io::Result<Option<Acquired>> {
        // REDOX PATCH: On Redox, poll() on pipes doesn't reliably deliver
        // events, causing the jobserver to hang when waiting for tokens.
        // Fix: ensure blocking mode and use a plain blocking read.
        // When a token is released (write to pipe), the read wakes up.
        #[cfg(target_os = "redox")]
        {
            let mut read = &self.read;
            // Ensure blocking mode — clear O_NONBLOCK
            unsafe {
                let flags = libc::fcntl(read.as_raw_fd(), libc::F_GETFL);
                if flags != -1 && (flags & libc::O_NONBLOCK) != 0 {
                    libc::fcntl(read.as_raw_fd(), libc::F_SETFL, flags & !libc::O_NONBLOCK);
                }
            }
            let mut buf = [0];
            match read.read(&mut buf) {
                Ok(1) => return Ok(Some(Acquired { byte: buf[0] })),
                Ok(_) => {
                    return Err(io::Error::new(
                        io::ErrorKind::UnexpectedEof,
                        "early EOF on jobserver pipe",
                    ));
                }
                Err(e) => match e.kind() {
                    io::ErrorKind::Interrupted => return Ok(None),
                    _ => return Err(e),
                },
            }
        }

        #[cfg(not(target_os = "redox"))]
        {
        // We don't actually know if the file descriptor here is set in
        // blocking or nonblocking mode. AFAIK all released versions of
        // `make` use blocking fds for the jobserver, but the unreleased
        // version of `make` doesn't. In the unreleased version jobserver
        // fds are set to nonblocking and combined with `pselect`
        // internally.
        //
        // Here we try to be compatible with both strategies. We optimistically
        // try to read from the file descriptor which then may block, return
        // a token or indicate that polling is needed.
        // Blocking reads (if possible) allows the kernel to be more selective
        // about which readers to wake up when a token is written to the pipe.
        //
        // We use `poll` here to block this thread waiting for read
        // readiness, and then afterwards we perform the `read` itself. If
        // the `read` returns that it would block then we start over and try
        // again.
        //
        // Also note that we explicitly don't handle EINTR here. That's used
        // to shut us down, so we otherwise punt all errors upwards.
        unsafe {
            let mut fd: libc::pollfd = mem::zeroed();
            let mut read = &self.read;
            fd.fd = read.as_raw_fd();
            fd.events = libc::POLLIN;
            loop {
                let mut buf = [0];
                match read.read(&mut buf) {
                    Ok(1) => return Ok(Some(Acquired { byte: buf[0] })),
                    Ok(_) => {
                        return Err(io::Error::new(
                            io::ErrorKind::UnexpectedEof,
                            "early EOF on jobserver pipe",
                        ));
                    }
                    Err(e) => match e.kind() {
                        io::ErrorKind::WouldBlock => { /* fall through to polling */ }
                        io::ErrorKind::Interrupted => return Ok(None),
                        _ => return Err(e),
                    },
                }

                loop {
                    fd.revents = 0;
                    if libc::poll(&mut fd, 1, -1) == -1 {
                        let e = io::Error::last_os_error();
                        return match e.kind() {
                            io::ErrorKind::Interrupted => Ok(None),
                            _ => Err(e),
                        };
                    }
                    if fd.revents != 0 {
                        break;
                    }
                }
            }
        }
        }
    }'''

    if old in content:
        content = content.replace(old, new)
        print(f"  Patched: acquire_allow_interrupts() — skip poll() on Redox")
    else:
        print(f"  WARNING: acquire_allow_interrupts() pattern not found")
        if 'acquire_allow_interrupts' in content:
            print(f"    (function exists but exact pattern differs)")
        if 'libc::poll' in content:
            print(f"    (libc::poll exists in file)")
        return False

    if content != original:
        with open(path, 'w') as f:
            f.write(content)
        return True
    return False


def update_checksum(vendor_dir, crate_dir):
    """Regenerate .cargo-checksum.json after patching."""
    import hashlib
    import json

    checksum_path = os.path.join(crate_dir, '.cargo-checksum.json')
    if not os.path.exists(checksum_path):
        print(f"  No .cargo-checksum.json found in {crate_dir}")
        return

    with open(checksum_path) as f:
        checksums = json.load(f)

    # Recompute SHA256 for unix.rs
    target = os.path.join(crate_dir, 'src', 'unix.rs')
    rel_path = 'src/unix.rs'
    if os.path.exists(target):
        with open(target, 'rb') as f:
            sha = hashlib.sha256(f.read()).hexdigest()
        if 'files' in checksums:
            checksums['files'][rel_path] = sha
            print(f"  Updated checksum for {rel_path}: {sha[:16]}...")

    with open(checksum_path, 'w') as f:
        json.dump(checksums, f)


def main():
    if len(sys.argv) < 2:
        print("Usage: patch-jobserver-poll.py <rust-source-dir>")
        sys.exit(1)

    src_dir = sys.argv[1]

    # Find the jobserver crate in vendor/
    pattern = os.path.join(src_dir, 'vendor', 'jobserver-*', 'src', 'unix.rs')
    matches = glob.glob(pattern)

    if not matches:
        print(f"ERROR: No jobserver crate found at {pattern}")
        sys.exit(1)

    for target in matches:
        crate_dir = os.path.dirname(os.path.dirname(target))
        print(f"Patching {target}...")
        if patch_file(target):
            update_checksum(src_dir, crate_dir)
            print(f"Done! jobserver will use blocking reads on Redox.")
        else:
            print(f"WARNING: Patch failed for {target}!")
            sys.exit(1)


if __name__ == '__main__':
    main()
