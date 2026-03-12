#!/usr/bin/env python3
"""
Patch relibc fork() to use a yield-based lock instead of futex-based RwLock.

Root cause: CLONE_LOCK uses futex-based RwLock. When a thread holds the
write lock and calls fork_impl(), the CoW address space duplication
copies the other thread's futex_wait kernel state. After unlock,
futex_wake() fails to wake the waiter — a Redox kernel bug where the
wake targets the wrong physical page after CoW.

Fix: Replace CLONE_LOCK with an AtomicI32-based RW lock using
sched_yield() instead of futex for waiting. This avoids the kernel
futex bug entirely.

- Positive value = reader count (concurrent thread creations)
- -1 = exclusive writer (fork in progress)
- 0 = unlocked

Target file: src/platform/redox/mod.rs (relibc source)
"""

import sys
import os


def patch_file(path):
    with open(path, "r") as f:
        content = f.read()

    original = content

    # 0. Remove unused RwLock import (CLONE_LOCK was the only user)
    old_import = "\n    sync::rwlock::RwLock,\n"
    new_import = "\n"
    if old_import in content:
        content = content.replace(old_import, new_import)
        print("  Patched: removed unused RwLock import")

    # 1. Replace CLONE_LOCK declaration
    old_decl = "static CLONE_LOCK: RwLock<()> = RwLock::new(());"
    new_decl = """// Yield-based RW lock for fork/clone serialization.
// Replaces futex-based RwLock which has a lost-wake bug on Redox:
// CoW address space duplication during fork copies futex_wait kernel
// state, causing futex_wake to target the wrong physical page.
// Values: 0 = unlocked, >0 = reader count, -1 = exclusive (fork)
static FORK_CLONE_LOCK: core::sync::atomic::AtomicI32 = core::sync::atomic::AtomicI32::new(0);"""

    if old_decl in content:
        content = content.replace(old_decl, new_decl)
        print("  Patched: CLONE_LOCK declaration → FORK_CLONE_LOCK AtomicI32")
    else:
        print(f"  WARNING: CLONE_LOCK declaration not found")
        return False

    # 2. Replace fork() to use yield-based exclusive lock
    old_fork = """    unsafe fn fork() -> Result<pid_t> {
        // TODO: Find way to avoid lock.
        let _guard = CLONE_LOCK.write();

        Ok(fork_impl(&redox_rt::proc::ForkArgs::Managed)? as pid_t)
    }"""

    new_fork = """    unsafe fn fork() -> Result<pid_t> {
        use core::sync::atomic::Ordering as AtomOrd;

        // Acquire exclusive lock (writers block readers and other writers)
        loop {
            match FORK_CLONE_LOCK.compare_exchange_weak(
                0, -1, AtomOrd::Acquire, AtomOrd::Relaxed
            ) {
                Ok(_) => break,
                Err(_) => { let _ = syscall::sched_yield(); }
            }
        }

        let pid = fork_impl(&redox_rt::proc::ForkArgs::Managed)? as pid_t;

        if pid == 0 {
            // Child: only one thread, reset lock directly
            FORK_CLONE_LOCK.store(0, AtomOrd::Release);
        }

        // Release exclusive lock
        FORK_CLONE_LOCK.store(0, AtomOrd::Release);

        Ok(pid)
    }"""

    if old_fork in content:
        content = content.replace(old_fork, new_fork)
        print("  Patched: fork() → yield-based exclusive lock")
    else:
        print(f"  WARNING: fork() pattern not found")
        return False

    # 3. Replace rlct_clone() to use yield-based shared lock
    old_clone = """    unsafe fn rlct_clone(
        stack: *mut usize,
        os_specific: &mut OsSpecific,
    ) -> Result<crate::pthread::OsTid> {
        let _guard = CLONE_LOCK.read();
        let res = unsafe { redox_rt::thread::rlct_clone_impl(stack, os_specific) };

        res.map(|thread_fd| crate::pthread::OsTid { thread_fd })
            .map_err(|error| Errno(error.errno))
    }"""

    new_clone = """    unsafe fn rlct_clone(
        stack: *mut usize,
        os_specific: &mut OsSpecific,
    ) -> Result<crate::pthread::OsTid> {
        use core::sync::atomic::Ordering as AtomOrd;

        // Acquire shared lock (readers block writers but not other readers)
        loop {
            let cur = FORK_CLONE_LOCK.load(AtomOrd::Relaxed);
            if cur >= 0 {
                match FORK_CLONE_LOCK.compare_exchange_weak(
                    cur, cur + 1, AtomOrd::Acquire, AtomOrd::Relaxed
                ) {
                    Ok(_) => break,
                    Err(_) => continue,
                }
            }
            let _ = syscall::sched_yield();
        }

        let res = unsafe { redox_rt::thread::rlct_clone_impl(stack, os_specific) };

        // Release shared lock
        FORK_CLONE_LOCK.fetch_sub(1, AtomOrd::Release);

        res.map(|thread_fd| crate::pthread::OsTid { thread_fd })
            .map_err(|error| Errno(error.errno))
    }"""

    if old_clone in content:
        content = content.replace(old_clone, new_clone)
        print("  Patched: rlct_clone() → yield-based shared lock")
    else:
        print(f"  WARNING: rlct_clone() pattern not found")
        return False

    if content != original:
        with open(path, "w") as f:
            f.write(content)
        return True
    return False


def patch_rwlock(path):
    """No-op: RwLock patches not needed since we replaced CLONE_LOCK"""
    print(f"  Skipped: RwLock patch not needed (using yield-based lock)")
    return True


def main():
    if len(sys.argv) < 2:
        print("Usage: patch-relibc-fork-lock.py <relibc-source-dir>")
        sys.exit(1)

    src_dir = sys.argv[1]

    mod_rs = os.path.join(src_dir, "src", "platform", "redox", "mod.rs")
    if not os.path.exists(mod_rs):
        print(f"ERROR: {mod_rs} not found")
        sys.exit(1)
    print(f"Patching {mod_rs}...")
    if not patch_file(mod_rs):
        sys.exit(1)

    print("Done! CLONE_LOCK replaced with yield-based RW lock.")


if __name__ == "__main__":
    main()
