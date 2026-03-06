#!/usr/bin/env python3
"""Patch relibc's abort() to use _exit(134) instead of intrinsics::abort() (ud2).

On Redox, intrinsics::abort() compiles to x86 ud2 (invalid opcode), which
triggers a kernel exception dump ("Invalid opcode fault") with a register dump
but no useful context. The parent process (e.g., cargo) sees the child killed
by an unrecoverable signal but gets no error message.

This matters especially for DSO copies of relibc (e.g., inside
librustc_driver.so), where the log::error!("Abort") call is silently
skipped because the logging framework hasn't been initialized (max log
level filter is 0/Off in BSS). The result: silent crash with no
diagnostic output.

Fix: Replace intrinsics::abort() with a write to stderr + Sys::exit(134).
134 = 128 + 6 (SIGABRT), the conventional exit code for abort().
The stderr write ensures the parent can see SOMETHING, and the clean exit
lets cargo report "rustc exited with code 134" instead of a kernel dump.
"""

import sys

path = "src/header/stdlib/mod.rs"
with open(path) as f:
    content = f.read()

old = """\
/// See <https://pubs.opengroup.org/onlinepubs/9799919799/functions/abort.html>.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn abort() -> ! {
    log::error!("Abort");
    intrinsics::abort();
}"""

new = """\
/// See <https://pubs.opengroup.org/onlinepubs/9799919799/functions/abort.html>.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn abort() -> ! {
    // Write to stderr directly via raw syscall. Do NOT use log::error!() here
    // because the logging framework may be uninitialized in DSO copies of
    // relibc (the log level filter is BSS-zeroed → Off, so the message is
    // silently discarded).
    let _ = Sys::write(2, b"relibc: abort() called\\n");
    Sys::exit(134)
}"""

if old not in content:
    print(f"  ERROR: could not find abort() pattern in {path}")
    print(f"  This likely means the relibc pin has been updated.")
    print(f"  Check if abort() still uses intrinsics::abort().")
    sys.exit(1)

content = content.replace(old, new, 1)

# Remove the now-unused `intrinsics` import to avoid compile error.
# Before: use core::{convert::TryFrom, intrinsics, iter, mem, ptr, slice};
# After:  use core::{convert::TryFrom, iter, mem, ptr, slice};
old_import = "use core::{convert::TryFrom, intrinsics, iter, mem, ptr, slice};"
new_import = "use core::{convert::TryFrom, iter, mem, ptr, slice};"

if old_import not in content:
    print(f"  WARNING: could not find intrinsics import to remove in {path}")
    print(f"  The unused import may cause a compile error.")
else:
    content = content.replace(old_import, new_import, 1)
    print(f"  Removed unused `intrinsics` import")

with open(path, 'w') as f:
    f.write(content)
print(f"  Patched {path}: abort() uses Sys::exit(134) instead of intrinsics::abort()")
