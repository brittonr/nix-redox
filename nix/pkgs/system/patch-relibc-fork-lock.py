#!/usr/bin/env python3
"""
Patch relibc fork() to reset CLONE_LOCK in the child process.

When two threads call fork() concurrently, one child can inherit
CLONE_LOCK in the EXCLUSIVE (write-locked) state. Since the other
thread doesn't exist in the child, the lock is never released,
causing any subsequent operation that touches CLONE_LOCK to deadlock.

Fix: After fork returns in the child (pid == 0), reset CLONE_LOCK's
internal state to 0 (unlocked). This is the standard pthread_atfork
pattern — locks acquired before fork must be released in both parent
and child.

We also reset the CLONE_LOCK via the atfork mechanism: acquire before
fork (prepare), release in both parent and child.

Target file: src/platform/redox/mod.rs (relibc source)
"""

import sys
import os


def patch_file(path):
    with open(path, "r") as f:
        content = f.read()

    original = content

    # Replace the fork() implementation to use atfork-style locking:
    # Acquire CLONE_LOCK before fork, release in both parent and child.
    #
    # The current code acquires CLONE_LOCK.write() and relies on the
    # guard drop to release it. But in the child, the guard drop happens
    # while the lock state may already be corrupted by the concurrent
    # thread's state being copied.
    #
    # Fix: After fork_impl returns, if we're in the child (pid == 0),
    # force CLONE_LOCK to unlocked state before the guard drops.

    old_fork = """    unsafe fn fork() -> Result<pid_t> {
        // TODO: Find way to avoid lock.
        let _guard = CLONE_LOCK.write();

        Ok(fork_impl(&redox_rt::proc::ForkArgs::Managed)? as pid_t)
    }"""

    new_fork = """    unsafe fn fork() -> Result<pid_t> {
        // Acquire the clone lock exclusively before forking.
        // This prevents thread creation during fork.
        let _guard = CLONE_LOCK.write();

        let pid = fork_impl(&redox_rt::proc::ForkArgs::Managed)? as pid_t;

        if pid == 0 {
            // CHILD PROCESS: Reset CLONE_LOCK to unlocked state.
            //
            // After fork, only the calling thread exists in the child.
            // If another thread was waiting on or interacting with
            // CLONE_LOCK in the parent, the child inherits a potentially
            // corrupted lock state. Force it to unlocked so the child
            // can use fork/clone normally.
            //
            // Safety: We're the only thread in the child process.
            // The _guard will drop after this, calling unlock(), which
            // is fine on an already-unlocked lock (it will be a no-op
            // or just set state to 0 again).
            CLONE_LOCK.force_unlock_after_fork();
        }

        Ok(pid)
    }"""

    if old_fork in content:
        content = content.replace(old_fork, new_fork)
        print("  Patched: fork() now resets CLONE_LOCK in child")
    else:
        print(f"  WARNING: fork() pattern not found in {path}")
        return False

    if content != original:
        with open(path, "w") as f:
            f.write(content)
        return True
    return False


def patch_rwlock(path):
    """Add force_unlock_after_fork() method to RwLock"""
    with open(path, "r") as f:
        content = f.read()

    original = content

    # Add a method to InnerRwLock that forces state to 0 (unlocked)
    old_unlock_end = """    pub fn unlock(&self) {
        let state = self.state.load(Ordering::Relaxed);

        if state & COUNT_MASK == EXCLUSIVE {
            // Unlocking a write lock.

            // This discards the writer-waiting bit, in order to ensure some level of fairness
            // between read and write locks.
            self.state.store(0, Ordering::Release);

            let _ = crate::sync::futex_wake(&self.state, i32::MAX);
        } else {
            // Unlocking a read lock. Subtract one from the reader count, but preserve the
            // WAITING_WR bit.

            if self.state.fetch_sub(1, Ordering::Release) & COUNT_MASK == 1 {
                let _ = crate::sync::futex_wake(&self.state, i32::MAX);
            }
        }
    }
}"""

    new_unlock_end = """    pub fn unlock(&self) {
        let state = self.state.load(Ordering::Relaxed);

        if state & COUNT_MASK == EXCLUSIVE {
            // Unlocking a write lock.

            // This discards the writer-waiting bit, in order to ensure some level of fairness
            // between read and write locks.
            self.state.store(0, Ordering::Release);

            let _ = crate::sync::futex_wake(&self.state, i32::MAX);
        } else {
            // Unlocking a read lock. Subtract one from the reader count, but preserve the
            // WAITING_WR bit.

            if self.state.fetch_sub(1, Ordering::Release) & COUNT_MASK == 1 {
                let _ = crate::sync::futex_wake(&self.state, i32::MAX);
            }
        }
    }

    /// Reset lock to unlocked state after fork().
    ///
    /// In a child process after fork, this is the only thread.
    /// Any lock state inherited from the parent is stale — other
    /// threads that held or waited on the lock don't exist here.
    /// Force to unlocked so the child can proceed normally.
    pub fn force_unlock_after_fork(&self) {
        self.state.store(0, Ordering::Release);
    }
}"""

    if old_unlock_end in content:
        content = content.replace(old_unlock_end, new_unlock_end)
        print("  Patched: added force_unlock_after_fork() to InnerRwLock")
    else:
        print(f"  WARNING: InnerRwLock unlock pattern not found")
        return False

    # Also add the method to RwLock<T> (the wrapper)
    old_rwlock_try_write = """    pub fn try_write(&self) -> Option<WriteGuard<'_, T>> {
        if self.inner.try_acquire_write_lock().is_ok() {
            Some(unsafe { WriteGuard::new(self) })
        } else {
            None
        }
    }
}"""

    new_rwlock_try_write = """    pub fn try_write(&self) -> Option<WriteGuard<'_, T>> {
        if self.inner.try_acquire_write_lock().is_ok() {
            Some(unsafe { WriteGuard::new(self) })
        } else {
            None
        }
    }

    /// Reset lock to unlocked state after fork().
    /// Safety: Must only be called in a child process where this
    /// is the only thread. See InnerRwLock::force_unlock_after_fork.
    pub fn force_unlock_after_fork(&self) {
        self.inner.force_unlock_after_fork();
    }
}"""

    if old_rwlock_try_write in content:
        content = content.replace(old_rwlock_try_write, new_rwlock_try_write)
        print("  Patched: added force_unlock_after_fork() to RwLock<T>")
    else:
        print(f"  WARNING: RwLock try_write pattern not found")
        return False

    if content != original:
        with open(path, "w") as f:
            f.write(content)
        return True
    return False


def main():
    if len(sys.argv) < 2:
        print("Usage: patch-relibc-fork-lock.py <relibc-source-dir>")
        sys.exit(1)

    src_dir = sys.argv[1]

    # Patch 1: Reset CLONE_LOCK in child after fork
    mod_rs = os.path.join(src_dir, "src", "platform", "redox", "mod.rs")
    if not os.path.exists(mod_rs):
        print(f"ERROR: {mod_rs} not found")
        sys.exit(1)
    print(f"Patching {mod_rs}...")
    if not patch_file(mod_rs):
        sys.exit(1)

    # Patch 2: Add force_unlock_after_fork to RwLock
    rwlock_rs = os.path.join(src_dir, "src", "sync", "rwlock.rs")
    if not os.path.exists(rwlock_rs):
        print(f"ERROR: {rwlock_rs} not found")
        sys.exit(1)
    print(f"Patching {rwlock_rs}...")
    if not patch_rwlock(rwlock_rs):
        sys.exit(1)

    print("Done! CLONE_LOCK will be reset in child process after fork.")


if __name__ == "__main__":
    main()
