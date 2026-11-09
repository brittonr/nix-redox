#!/usr/bin/env python3
"""Port strace-redox's process syscalls to relibc.

strace-redox links redox_syscall 0.3.4, whose getpid/kill/waitpid issue
legacy syscalls that the refreshed Redox kernel rejects with ENOSYS. relibc
routes the same operations through the proc: scheme, so use libc here.
"""

import os
import sys


def replace(path, old, new):
    with open(path) as f:
        text = f.read()
    if text.count(old) != 1:
        raise SystemExit(f"{path}: expected one anchor: {old[:80]!r}")
    with open(path, "w") as f:
        f.write(text.replace(old, new, 1))


main = os.path.join(sys.argv[1], "src/main.rs")

replace(
    main,
    """fn e<T>(res: syscall::Result<T>) -> Result<T> {
    res.map_err(|err| Error::from_raw_os_error(err.errno))
}""",
    """fn e_libc(res: libc::c_int) -> Result<libc::c_int> {
    if res == -1 {
        Err(Error::last_os_error())
    } else {
        Ok(res)
    }
}""",
)

replace(
    main,
    "    e(syscall::kill(e(syscall::getpid())?, syscall::SIGSTOP))?;",
    "    // Let the tracer attach without a stop/continue signal pair: SIGCONT\n"
    "    // left pending in the tracee spuriously wakes futex waiters.\n"
    "    unsafe { libc::usleep(500_000); }",
)

replace(
    main,
    "    e(syscall::waitpid(pid, &mut status, syscall::WUNTRACED))?;",
    "    // The child sleeps briefly instead of stopping; attach directly.",
)

replace(
    main,
    "    e(syscall::kill(pid, syscall::SIGCONT))?;",
    "    // The kernel resumes the tracee when the tracer writes trace flags.\n"
    "    // Sending SIGCONT here leaves a pending signal and spuriously wakes\n"
    "    // futex waiters in the tracee, which can spin in relibc.",
)

replace(main, "Some(syscall::ESRCH)", "Some(libc::ESRCH)")

replace(
    main,
    "            e(syscall::waitpid(pid, &mut status, syscall::WNOHANG))?;",
    "            e_libc(unsafe { libc::waitpid(pid as libc::pid_t, &mut status, libc::WNOHANG) })?;",
)

replace(main, "if syscall::wifexited(status)", "if libc::WIFEXITED(status)")
replace(main, "syscall::wexitstatus(status)", "libc::WEXITSTATUS(status)")
replace(main, "if syscall::wifsignaled(status)", "if libc::WIFSIGNALED(status)")
replace(main, "syscall::wtermsig(status)", "libc::WTERMSIG(status)")

print("Patched strace-redox process calls to libc")
