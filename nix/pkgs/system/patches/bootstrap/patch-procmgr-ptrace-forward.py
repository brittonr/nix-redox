#!/usr/bin/env python3
"""Patch procmgr to forward ptrace handle opens to the kernel.

When userspace opens proc:<pid>/trace or proc:<pid>/mem, the namespace
manager routes through procmgr (the userspace proc: scheme handler).
Procmgr needs to forward these to the kernel's proc scheme, which has
the actual Trace and Memory handle implementations.

The fix adds PID/operation path parsing to procmgr's openat handler.
For operations that should be handled by the kernel (trace, mem, regs/*,
etc.), procmgr looks up the process, gets a thread's kernel fd, and
dups the operation on it. The kernel's kdup handler for OpenViaDup
dispatches to openat_context which handles "trace", "mem", etc.
"""

import sys
import os


def patch_file(filepath, old, new):
    with open(filepath, "r") as f:
        content = f.read()
    if old not in content:
        print(f"WARNING: patch target not found in {filepath}")
        print(f"  Looking for: {repr(old[:100])}...")
        return False
    content = content.replace(old, new, 1)
    with open(filepath, "w") as f:
        f.write(content)
    print(f"  Patched {filepath}")
    return True


def patch_procmgr(src_dir):
    """Add PID/operation forwarding to procmgr's openat handler."""

    procmgr_file = os.path.join(src_dir, "bootstrap/src/procmgr.rs")

    # Replace the catch-all ENOENT in openat with PID/operation forwarding
    patch_file(
        procmgr_file,
        """            _ => return Err(Error::new(ENOENT)),
        })
    }
    fn read_process_metadata""",
        """            _ => {
                // Try parsing as "<pid>/<operation>" for kernel-forwarded operations.
                // Operations like "trace", "mem", "regs/int", "regs/float" are handled
                // by the kernel's proc scheme. We find the process, get a thread's
                // kernel fd, and dup the operation path on it.
                if let Some(slash_pos) = path.find('/') {
                    let pid_str = &path[..slash_pos];
                    let operation = &path[slash_pos + 1..];
                    if let Ok(pid_num) = pid_str.parse::<usize>() {
                        let pid = ProcessId(pid_num);
                        let proc_rc = self.processes.get(&pid).ok_or(Error::new(ESRCH))?;
                        let process = proc_rc.borrow();
                        let thread = process.threads.first().ok_or(Error::new(ESRCH))?;
                        let thread = thread.borrow();
                        // Forward to the kernel's proc scheme via the thread's kernel fd
                        let fd = thread.fd.dup(operation.as_bytes())?.take();
                        return Ok(OpenResult::OtherScheme { fd });
                    }
                }
                return Err(Error::new(ENOENT));
            }
        })
    }
    fn read_process_metadata""",
    )

    print("procmgr patched: PID/operation forwarding to kernel added")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <base-source-dir>")
        sys.exit(1)
    patch_procmgr(sys.argv[1])
