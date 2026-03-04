#!/usr/bin/env python3
"""
Patch Rust std's process spawning to avoid the CLOEXEC error pipe on Redox.

After fork(), the parent reads from a CLOEXEC pipe to detect exec() failures.
On Redox, this blocking pipe read crashes (Invalid opcode) when the child
process is non-trivial. Fix: skip the error pipe read and rely on waitpid()
to detect exec failures instead.

Target file: library/std/src/sys/process/unix/unix.rs
"""

import sys
import os

def patch_file(path):
    with open(path, 'r') as f:
        content = f.read()

    original = content

    # Suppress unused import warning for Error (only used in CLOEXEC path)
    old_use = 'use crate::io::{self, Error, ErrorKind};'
    if old_use in content:
        content = content.replace(old_use, '#[allow(unused_imports)]\n' + old_use, 1)
        print(f"  Added allow(unused_imports) for Error")

    # Add allow(unused_mut) to spawn() for the `mut p` variable
    old_fn = '    pub fn spawn(\n        &mut self,'
    new_fn = '    #[allow(unused_mut)]\n    pub fn spawn(\n        &mut self,'
    if old_fn in content:
        content = content.replace(old_fn, new_fn)
        print(f"  Added allow(unused_mut) to spawn()")

    # The spawn function has this flow after fork (parent side):
    #   drop(env_lock);
    #   drop(output);
    #   ... pidfd handling ...
    #   let mut p = unsafe { Process::new(pid, pidfd) };
    #   let mut bytes = [0; 8];
    #   loop {
    #       match input.read(&mut bytes) {
    #           Ok(0) => return Ok((p, ours)),
    #           ...
    #       }
    #   }
    #
    # Replace the pipe-reading loop with just returning success.
    # If exec() fails, waitpid() will report the child's exit status.
    # We lose the specific errno, but avoid the pipe read crash on Redox.

    old = '''        let mut bytes = [0; 8];

        // loop to handle EINTR
        loop {
            match input.read(&mut bytes) {
                Ok(0) => return Ok((p, ours)),
                Ok(8) => {
                    let (errno, footer) = bytes.split_at(4);
                    assert_eq!(
                        CLOEXEC_MSG_FOOTER, footer,
                        "Validation on the CLOEXEC pipe failed: {:?}",
                        bytes
                    );
                    let errno = i32::from_be_bytes(errno.try_into().unwrap());
                    assert!(p.wait().is_ok(), "wait() should either return Ok or panic");
                    return Err(Error::from_raw_os_error(errno));
                }
                Err(ref e) if e.is_interrupted() => {}
                Err(e) => {
                    assert!(p.wait().is_ok(), "wait() should either return Ok or panic");
                    panic!("the CLOEXEC pipe failed: {e:?}")
                }
                Ok(..) => {
                    // pipe I/O up to PIPE_BUF bytes should be atomic
                    // similarly SOCK_SEQPACKET messages should arrive whole
                    assert!(p.wait().is_ok(), "wait() should either return Ok or panic");
                    panic!("short read on the CLOEXEC pipe")
                }
            }
        }'''

    new = '''        // REDOX PATCH: Skip CLOEXEC error pipe on Redox.
        // On Redox, blocking pipe reads crash (Invalid opcode) when the
        // child process runs for non-trivial time. Close the pipe and
        // return success. If exec() failed, waitpid() will report exit.
        #[cfg(target_os = "redox")]
        {
            drop(input);
            #[allow(unused_mut)]
            return Ok((p, ours));
        }

        #[cfg(not(target_os = "redox"))]
        {
        let mut bytes = [0; 8];

        // loop to handle EINTR
        loop {
            match input.read(&mut bytes) {
                Ok(0) => return Ok((p, ours)),
                Ok(8) => {
                    let (errno, footer) = bytes.split_at(4);
                    assert_eq!(
                        CLOEXEC_MSG_FOOTER, footer,
                        "Validation on the CLOEXEC pipe failed: {:?}",
                        bytes
                    );
                    let errno = i32::from_be_bytes(errno.try_into().unwrap());
                    assert!(p.wait().is_ok(), "wait() should either return Ok or panic");
                    return Err(Error::from_raw_os_error(errno));
                }
                Err(ref e) if e.is_interrupted() => {}
                Err(e) => {
                    assert!(p.wait().is_ok(), "wait() should either return Ok or panic");
                    panic!("the CLOEXEC pipe failed: {e:?}")
                }
                Ok(..) => {
                    // pipe I/O up to PIPE_BUF bytes should be atomic
                    // similarly SOCK_SEQPACKET messages should arrive whole
                    assert!(p.wait().is_ok(), "wait() should either return Ok or panic");
                    panic!("short read on the CLOEXEC pipe")
                }
            }
        }
        }'''

    if old in content:
        content = content.replace(old, new)
        print(f"  Patched: spawn() CLOEXEC error pipe reading → skip")
    else:
        print(f"  WARNING: spawn() CLOEXEC pattern not found")
        # Try to find the approximate location for debugging
        if 'CLOEXEC_MSG_FOOTER' in content:
            print(f"    (CLOEXEC_MSG_FOOTER exists but exact pattern differs)")
        return False

    if content != original:
        with open(path, 'w') as f:
            f.write(content)
        return True
    return False

def main():
    if len(sys.argv) < 2:
        print("Usage: patch-rustc-spawn-pipes.py <rust-source-dir>")
        sys.exit(1)

    src_dir = sys.argv[1]
    target = os.path.join(src_dir, 'library', 'std', 'src', 'sys', 'process', 'unix', 'unix.rs')

    if not os.path.exists(target):
        print(f"ERROR: {target} not found")
        sys.exit(1)

    print(f"Patching {target}...")
    if patch_file(target):
        print("Done! Spawn will skip CLOEXEC pipe reading.")
    else:
        print("WARNING: Patch failed!")
        sys.exit(1)

if __name__ == '__main__':
    main()
