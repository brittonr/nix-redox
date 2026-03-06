#!/usr/bin/env python3
"""Patch relibc's chdir() to avoid deadlock on the CWD Mutex after fork().

Backport of upstream relibc commit 9cde64a3 (Mar 01 2026).

Root cause: relibc's CWD is protected by a non-reentrant Mutex. The path::open()
function (called for every file open) temporarily acquires CWD.lock(). If any
thread in a multi-threaded process (like cargo) holds CWD.lock() at the moment
of fork(), the child process inherits the mutex in LOCKED state. When the child
calls chdir() (from Command::current_dir() setup before exec()), CWD.lock()
enters futex_wait — but no thread exists in the child to call futex_wake.
Result: the child hangs forever, and cargo blocks on the empty stdout pipe.

Fix: chdir() uses try_lock() first. If it fails (stale lock from parent after
fork), force-reset the mutex and retry. After fork(), only one thread exists
in the child, so force-unlocking is safe. In the normal multi-threaded case,
try_lock() succeeds because chdir is called with signals disabled and is
the only function that write-locks CWD for an extended period.
"""

import sys

path = "src/platform/redox/path.rs"
with open(path) as f:
    content = f.read()

# The exact text we're replacing in chdir():
old = """\
    let _siglock = tmp_disable_signals();
    let mut cwd_guard = CWD.lock();"""

new = """\
    let _siglock = tmp_disable_signals();
    // Use try_lock to avoid deadlock in post-fork children. After fork(), the
    // child inherits the parent's CWD Mutex state. If any parent thread held
    // CWD.lock() at fork time, the child's copy is stuck in LOCKED state with
    // no thread to unlock it. try_lock() detects this and force-resets the
    // mutex. Safe because the child is single-threaded after fork().
    let mut cwd_guard = CWD.try_lock().unwrap_or_else(|| {
        unsafe { CWD.manual_unlock(); }
        CWD.lock()
    });"""

if old not in content:
    print(f"  ERROR: could not find CWD.lock() pattern in chdir() in {path}")
    print(f"  This likely means the relibc pin has been updated.")
    print(f"  If the pin includes upstream commit 9cde64a3 or later,")
    print(f"  this patch is no longer needed and should be removed.")
    sys.exit(1)

content = content.replace(old, new, 1)  # Replace only the first occurrence (in chdir)

with open(path, 'w') as f:
    f.write(content)
print(f"  Patched {path}: chdir() uses try_lock() to prevent post-fork deadlock")
