#!/usr/bin/env python3
"""Patch relibc to make fcntl file locking (F_SETLK/F_SETLKW/F_GETLK) a no-op.

Redox kernel does not implement POSIX file locking. When fcntl(F_SETLKW) is
forwarded to the kernel, it may hang indefinitely. This causes cargo to freeze
on its .package-cache lock.

Fix: intercept F_SETLK/F_SETLKW/F_GETLK in Sys::fcntl() and return 0 (success)
immediately, matching the existing flock() no-op behavior.
"""
import sys
import os

def patch_file(path, old, new):
    with open(path, 'r') as f:
        content = f.read()
    if old not in content:
        print(f"ERROR: Pattern not found in {path}")
        print(f"Looking for: {repr(old[:80])}...")
        sys.exit(1)
    content = content.replace(old, new)
    with open(path, 'w') as f:
        f.write(content)
    print(f"Patched {path}")

# Patch src/platform/redox/mod.rs: intercept F_SETLK/F_SETLKW/F_GETLK in fcntl
patch_file(
    "src/platform/redox/mod.rs",
    """    fn fcntl(fd: c_int, cmd: c_int, args: c_ulonglong) -> Result<c_int> {
        Ok(syscall::fcntl(fd as usize, cmd as usize, args as usize)? as c_int)
    }""",
    """    fn fcntl(fd: c_int, cmd: c_int, args: c_ulonglong) -> Result<c_int> {
        use crate::header::fcntl::{F_GETLK, F_SETLK, F_SETLKW, F_OFD_GETLK, F_OFD_SETLK, F_OFD_SETLKW};
        // Redox does not implement POSIX file locking. Forwarding F_SETLKW to
        // the kernel hangs indefinitely (e.g., cargo's .package-cache lock).
        // Return success immediately, matching the flock() no-op.
        match cmd {
            F_SETLK | F_SETLKW | F_OFD_SETLK | F_OFD_SETLKW => return Ok(0),
            F_GETLK | F_OFD_GETLK => {
                // For GETLK, set l_type = F_UNLCK to indicate no conflicting lock
                if args != 0 {
                    unsafe {
                        let flock = args as *mut crate::header::fcntl::flock;
                        (*flock).l_type = 2; // F_UNLCK
                    }
                }
                return Ok(0);
            }
            _ => {}
        }
        Ok(syscall::fcntl(fd as usize, cmd as usize, args as usize)? as c_int)
    }"""
)

print("Done: fcntl file locking is now a no-op on Redox")
