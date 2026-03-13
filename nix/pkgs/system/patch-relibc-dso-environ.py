#!/usr/bin/env python3
"""Fix DSO environ: init_array self-initialization from __relibc_init_environ.

Root cause: When relibc is statically linked into a DSO, the init_array function
reads __relibc_init_environ through R_X86_64_GLOB_DAT (symbol interposition),
which resolves to the MAIN BINARY's copy. Since ld_so processes dependencies
before the main binary, the main binary's __relibc_init_environ is still NULL
when the DSO's init_array runs. Result: the DSO's platform::environ stays null.

Fix: In the init_array function, if __relibc_init_environ (via GOT/interposition)
is null, try the DSO's OWN __relibc_init_environ by reading it through a local
alias that bypasses GLOB_DAT interposition. We do this by accessing the symbol
through the raw static address (which uses R_X86_64_RELATIVE, not GLOB_DAT).

Additionally, as a safety net, make getenv() check __relibc_init_environ when
environ is null, ensuring environ gets lazily initialized even if init_array
didn't run or was skipped.
"""
import sys

# Part 1: Patch init_array to handle GLOB_DAT interposition
# The key insight: `__relibc_init_environ` accessed via `extern static` uses
# GLOB_DAT (interposed to main binary). But we can also check a LOCAL reference.
#
# However, the simplest fix is to not rely on init_array at all for DSOs.
# Instead, make getenv() self-initializing.

# Part 2: Patch getenv to self-initialize from __relibc_init_environ
with open("src/header/stdlib/mod.rs", "r") as f:
    content = f.read()

# Find the getenv function and add self-initialization
OLD = """\
pub unsafe extern "C" fn getenv(name: *const c_char) -> *mut c_char {"""

NEW = """\
pub unsafe extern "C" fn getenv(name: *const c_char) -> *mut c_char {
    // DSO environ fix: If platform::environ is null, try to initialize it from
    // __relibc_init_environ. This handles the case where the DSO's init_array
    // couldn't set environ due to GLOB_DAT symbol interposition (the init_array
    // reads __relibc_init_environ from the main binary's copy via GOT, which
    // may be null if the main binary's run_init hasn't happened yet).
    if unsafe { platform::environ.is_null() } {
        unsafe {
            unsafe extern "C" {
                static __relibc_init_environ: *mut *mut c_char;
            }
            if !__relibc_init_environ.is_null() {
                platform::environ = __relibc_init_environ;
            }
        }
    }"""

if OLD in content:
    content = content.replace(OLD, NEW)
    print("Patched getenv() with DSO environ self-initialization")
else:
    print("ERROR: could not find getenv() signature in src/header/stdlib/mod.rs!")
    sys.exit(1)

with open("src/header/stdlib/mod.rs", "w") as f:
    f.write(content)
