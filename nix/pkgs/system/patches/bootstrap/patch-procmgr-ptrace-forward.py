#!/usr/bin/env python3
"""Patch procmgr to forward ptrace handle opens to the kernel.

When userspace opens proc:<pid>/trace or proc:<pid>/mem, the namespace
manager routes through procmgr (the userspace proc: scheme handler).
Procmgr needs to forward these to the kernel's proc scheme, which has
the actual Trace and Memory handle implementations.

The fix adds root-only PID/operation parsing to procmgr's scheme-root
openat handler. Only trace, mem, regs/int and regs/float are forwarded,
matching strace-redox and gdbstub consumers. Never expose arbitrary dup
operations through procmgr's privileged thread descriptor.
"""

import sys
import os


def patch_file(filepath, old, new):
    with open(filepath, "r") as f:
        content = f.read()
    if content.count(old) != 1:
        raise SystemExit(f"ptrace forwarding patch: expected one target in {filepath}")
    content = content.replace(old, new, 1)
    with open(filepath, "w") as f:
        f.write(content)
    print(f"  Patched {filepath}")
    return True


def patch_procmgr(src_dir):
    """Add PID/operation forwarding to the scheme-root openat handler."""
    procmgr_file = os.path.join(src_dir, "bootstrap/src/procmgr.rs")
    patch_file(
        procmgr_file,
        """                    _ => Err(Error::new(ENOENT)),
                }
            }
            Handle::Proc(pid) => {""",
        """                    _ => {
                        // Forward PID/operation paths to the kernel proc scheme.
                        if let Some((pid, operation)) = path.split_once('/') {
                            if let Ok(pid) = pid.parse::<usize>() {
                                if !matches!(operation, "trace" | "mem" | "regs/int" | "regs/float") {
                                    return Err(Error::new(ENOENT));
                                }
                                if ctx.uid != 0 {
                                    return Err(Error::new(EACCES));
                                }
                                let proc_rc = self.processes.get(&ProcessId(pid))
                                    .ok_or(Error::new(ESRCH))?;
                                let process = proc_rc.borrow();
                                let thread = process.threads.first().ok_or(Error::new(ESRCH))?;
                                let thread = thread.borrow();
                                let fd = thread.fd.dup(operation.as_bytes())?.take();
                                return Ok(OpenResult::OtherScheme { fd });
                            }
                        }
                        Err(Error::new(ENOENT))
                    }
                }
            }
            Handle::Proc(pid) => {""",
    )
    print("procmgr patched: PID/operation forwarding to kernel added")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <base-source-dir>")
        sys.exit(1)
    patch_procmgr(sys.argv[1])
