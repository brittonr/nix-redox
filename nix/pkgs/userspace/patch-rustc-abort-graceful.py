#!/usr/bin/env python3
"""Patch Rust std abort_internal to log + _exit(134) on Redox instead of ud2.

On Redox, the abort intrinsic (ud2) causes an UNHANDLED EXCEPTION that:
1. Doesn't deliver SIGABRT to the parent's waitpid
2. Doesn't flush stderr buffers
3. Generates a kernel crash dump that obscures the actual error

This patch makes abort_internal() write a diagnostic to /tmp/abort.log,
close stdout/stderr (to signal pipe EOF to parent), and call _exit(134)
on Redox, which allows clean process termination.
"""

import sys
import os

base = sys.argv[1] if len(sys.argv) > 1 else "."

mod_file = os.path.join(base, "library/std/src/sys/pal/unix/mod.rs")
with open(mod_file, 'r') as f:
    lines = f.readlines()

# Find the abort_internal function and replace its body
found = False
for i, line in enumerate(lines):
    if 'fn abort_internal() -> !' in line and 'pub' in line:
        print(f"Found abort_internal at line {i+1}: {line.strip()}")
        for j in range(i, min(i+5, len(lines))):
            print(f"  Line {j+1}: {lines[j].rstrip()}")

        # Find matching closing brace
        brace_count = 0
        start = i
        end = i
        for j in range(i, len(lines)):
            brace_count += lines[j].count('{') - lines[j].count('}')
            if brace_count == 0 and j > i:
                end = j
                break

        # Build replacement with file logging on Redox, unchanged on Linux
        # IMPORTANT: Rust 2024 edition requires `unsafe extern "C"`, not bare `extern "C"`
        # IMPORTANT: Must not add unnecessary unsafe blocks (deny(unused_unsafe) on Linux)
        new_lines = [
            'pub fn abort_internal() -> ! {\n',
            '    #[cfg(target_os = "redox")]\n',
            '    {\n',
            '        // On Redox, ud2 causes kernel UNHANDLED EXCEPTION that hangs waitpid.\n',
            '        // Log diagnostic info, close pipes, and use _exit(134) for clean termination.\n',
            '        unsafe extern "C" {\n',
            '            fn open(path: *const u8, flags: i32, mode: i32) -> i32;\n',
            '            fn write(fd: i32, buf: *const u8, count: usize) -> isize;\n',
            '            fn close(fd: i32) -> i32;\n',
            '            fn getpid() -> i32;\n',
            '            fn _exit(status: i32) -> !;\n',
            '        }\n',
            '        unsafe {\n',
            '            let path = b"/tmp/abort.log\\0";\n',
            '            // O_WRONLY(0x20000)|O_CREAT(0x2000000)|O_APPEND(0x8000000) on Redox\n',
            '            let fd = open(path.as_ptr(), 0x0A020000, 0o644);\n',
            '            if fd >= 0 {\n',
            '                let pid = getpid();\n',
            '                let mut buf = [0u8; 64];\n',
            '                let msg = b"abort_internal called, pid=";\n',
            '                let _ = write(fd, msg.as_ptr(), msg.len());\n',
            '                let mut n = pid as u32;\n',
            '                let mut pos = buf.len();\n',
            '                if n == 0 { pos -= 1; buf[pos] = b\'0\'; }\n',
            '                while n > 0 { pos -= 1; buf[pos] = b\'0\' + (n % 10) as u8; n /= 10; }\n',
            '                let _ = write(fd, buf[pos..].as_ptr(), buf.len() - pos);\n',
            '                let nl = b"\\n";\n',
            '                let _ = write(fd, nl.as_ptr(), 1);\n',
            '                close(fd);\n',
            '            }\n',
            '            // Close stdout/stderr to signal pipe EOF to parent process.\n',
            '            // On Redox, _exit() may not properly close pipe FDs,\n',
            '            // causing the parent (cargo) to hang on read() forever.\n',
            '            close(1);\n',
            '            close(2);\n',
            '            close(0);\n',
            '            // Close any other FDs that might be pipes (3-31)\n',
            '            let mut fd_i: i32 = 3;\n',
            '            while fd_i < 32 {\n',
            '                close(fd_i);\n',
            '                fd_i += 1;\n',
            '            }\n',
            '            _exit(134);\n',
            '        }\n',
            '    }\n',
            '    #[cfg(not(target_os = "redox"))]\n',
        ]
        # Append original body lines for non-Redox
        for j in range(i+1, end+1):
            new_lines.append(lines[j])

        lines[start:end+1] = new_lines
        found = True
        print(f"Patched abort_internal (lines {start+1}-{end+1}) → file log + close FDs + _exit(134) on Redox")
        break

if found:
    with open(mod_file, 'w') as f:
        f.writelines(lines)
else:
    print(f"ERROR: Could not find abort_internal() in {mod_file}")
    sys.exit(1)
