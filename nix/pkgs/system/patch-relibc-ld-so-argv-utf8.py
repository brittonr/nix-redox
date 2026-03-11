#!/usr/bin/env python3
"""Patch ld_so to handle non-UTF-8 argv without crashing.

Root cause: ld_so's get_argv() uses CStr::to_str() which requires valid UTF-8.
When an argv entry contains non-UTF-8 bytes (e.g. Polish characters in
CARGO_PKG_AUTHORS passed via --env-set), ld_so calls _exit(1) and kills the
process before it even starts.

This is wrong on two levels:
1. POSIX makes no UTF-8 guarantee for argv — arbitrary bytes (except NUL) are valid
2. ld_so only uses argv[0] (or argv[1] in manual mode) — it parses ALL entries
   into Vec<String> just to crash on entry N that it never reads

Note: get_env() already handles this correctly — it silently skips non-UTF-8
entries with `if let Ok(...)`. Only get_argv is fatal.

Fix: Use to_string_lossy() which replaces invalid UTF-8 sequences with U+FFFD.
This preserves all valid text and makes ld_so resilient to any byte sequence in
argv. The loaded program reads argv directly from the stack (not from ld_so's
parsed Vec), so lossy conversion has zero impact on the application.

Symptoms fixed:
- generic-array build failure (CARGO_PKG_AUTHORS contains ł, ń)
- Any crate with non-ASCII metadata passed through --env-set
- 4 of 57 self-hosting tests that previously failed
"""

import sys
import os

base = sys.argv[1] if len(sys.argv) > 1 else "."
start_path = os.path.join(base, "src/ld_so/start.rs")

with open(start_path, 'r') as f:
    content = f.read()

old = """unsafe fn get_argv(mut ptr: *const usize) -> (Vec<String>, *const usize) {
    //traverse the stack and collect argument vector
    let mut argv = Vec::new();
    while unsafe { *ptr != 0 } {
        let arg = unsafe { *ptr };
        match unsafe { CStr::from_ptr(arg as *const c_char).to_str() } {
            Ok(arg_str) => argv.push(arg_str.to_owned()),
            _ => {
                eprintln!("ld.so: failed to parse argv[{}]", argv.len());
                unistd::_exit(1);
            }
        }
        ptr = unsafe { ptr.add(1) };
    }

    (argv, ptr)
}"""

new = """unsafe fn get_argv(mut ptr: *const usize) -> (Vec<String>, *const usize) {
    //traverse the stack and collect argument vector
    let mut argv = Vec::new();
    while unsafe { *ptr != 0 } {
        let arg = unsafe { *ptr };
        let cstr = unsafe { CStr::from_ptr(arg as *const c_char) };
        // Use lossy conversion instead of crashing on non-UTF-8 argv entries.
        // POSIX allows arbitrary bytes in argv, and ld_so only uses argv[0].
        // The loaded program reads argv from the stack directly, not from this Vec.
        argv.push(cstr.to_string_lossy().into_owned());
        ptr = unsafe { ptr.add(1) };
    }

    (argv, ptr)
}"""

if old in content:
    content = content.replace(old, new)
    with open(start_path, 'w') as f:
        f.write(content)
    print(f"  Patched {start_path}: get_argv uses to_string_lossy() instead of _exit(1)")
else:
    if "to_string_lossy" in content and "get_argv" in content:
        print(f"  {start_path}: already patched with to_string_lossy, skipping")
    else:
        print(f"  ERROR: Could not find get_argv pattern in {start_path}")
        # Show context for debugging
        if "get_argv" in content:
            idx = content.index("get_argv")
            ctx = content[idx:idx+500]
            print(f"  Context:\n{ctx}")
        sys.exit(1)
