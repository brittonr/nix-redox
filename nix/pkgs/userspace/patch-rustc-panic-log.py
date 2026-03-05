#!/usr/bin/env python3
"""Patch Rust std panic handler to log panic messages to /tmp/panic.log on Redox.

When rustc panics as a cargo subprocess, stderr goes to cargo's pipe.
If cargo hangs reading, the panic message is lost. This patch adds
a file-based panic logger that captures the location to /tmp/panic.log
so we can diagnose what went wrong.

Target file: library/std/src/panicking.rs
"""

import sys
import os

base = sys.argv[1] if len(sys.argv) > 1 else "."
target = os.path.join(base, "library/std/src/panicking.rs")

with open(target, 'r') as f:
    content = f.read()

# Find panic_with_hook function — this is called for ALL panics
marker = 'fn panic_with_hook('
if marker not in content:
    print(f"ERROR: Could not find {marker} in {target}")
    sys.exit(1)

# Find the opening brace of the function body
idx = content.index(marker)
# Find ') -> ! {' pattern
body_start = content.index(') -> ! {', idx)
brace_idx = content.index('{', body_start)

# Insert Redox-specific file logging right after the opening brace.
# Use raw syscalls (like the abort patch) to avoid any std dependencies
# that could themselves panic and cause recursion.
log_code = """
    // REDOX PATCH: Log panic location to /tmp/panic.log via raw syscalls.
    // When rustc is a subprocess of cargo, stderr goes to a pipe.
    // If cargo hangs, the panic message is lost. File logging preserves it.
    // Uses raw syscalls to avoid recursion (std I/O could panic again).
    #[cfg(target_os = "redox")]
    {
        unsafe {
            unsafe extern "C" {
                fn open(path: *const u8, flags: i32, mode: i32) -> i32;
                fn write(fd: i32, buf: *const u8, count: usize) -> isize;
                fn close(fd: i32) -> i32;
                fn getpid() -> i32;
            }
            let path = b"/tmp/panic.log\\0";
            // O_WRONLY|O_CREAT|O_APPEND on Redox
            let fd = open(path.as_ptr(), 0x0A020000, 0o644);
            if fd >= 0 {
                let _ = write(fd, b"PANIC pid=".as_ptr(), 10);
                let pid = getpid();
                let mut buf = [0u8; 16];
                let mut n = pid as u32;
                let mut pos = buf.len();
                if n == 0 { pos -= 1; buf[pos] = b'0'; }
                while n > 0 { pos -= 1; buf[pos] = b'0' + (n % 10) as u8; n /= 10; }
                let _ = write(fd, buf[pos..].as_ptr(), buf.len() - pos);
                let _ = write(fd, b" at ".as_ptr(), 4);
                let loc_file = location.file().as_bytes();
                let _ = write(fd, loc_file.as_ptr(), loc_file.len());
                let _ = write(fd, b":".as_ptr(), 1);
                let line = location.line();
                let mut n2 = line;
                pos = buf.len();
                if n2 == 0 { pos -= 1; buf[pos] = b'0'; }
                while n2 > 0 { pos -= 1; buf[pos] = b'0' + (n2 % 10) as u8; n2 /= 10; }
                let _ = write(fd, buf[pos..].as_ptr(), buf.len() - pos);
                let _ = write(fd, b" can_unwind=".as_ptr(), 12);
                if can_unwind { let _ = write(fd, b"true".as_ptr(), 4); }
                else { let _ = write(fd, b"false".as_ptr(), 5); }
                let _ = write(fd, b"\\n".as_ptr(), 1);
                close(fd);
            }
        }
    }
"""

content = content[:brace_idx+1] + log_code + content[brace_idx+1:]

with open(target, 'w') as f:
    f.write(content)

print(f"Patched {target}: added panic file logging on Redox")
