#!/usr/bin/env python3
"""Patch relibc getenv to print diagnostic when looking up DIAG_TEST_VAR.
This tells us the state of environ at the moment getenv is actually called."""
import sys

with open("src/header/stdlib/mod.rs", "r") as f:
    content = f.read()

# Patch find_env to add a diagnostic before the search
OLD = """\
pub unsafe extern "C" fn getenv(name: *const c_char) -> *mut c_char {
    unsafe { find_env(name) }
        .map(|val| val.1)
        .unwrap_or(ptr::null_mut())
}"""

NEW = """\
pub unsafe extern "C" fn getenv(name: *const c_char) -> *mut c_char {
    // Diagnostic: when looking up vars starting with "DIAG", dump environ state
    let name_cstr = unsafe { core::ffi::CStr::from_ptr(name) };
    if let Ok(name_str) = core::str::from_utf8(name_cstr.to_bytes()) {
        if name_str.starts_with("DIAG") {
            let env_ptr = unsafe { core::ptr::addr_of!(platform::environ).read() };
            let env_null = env_ptr.is_null();
            let mut count = 0usize;
            if !env_null {
                unsafe {
                    let mut p = env_ptr;
                    while !(*p).is_null() {
                        count += 1;
                        p = p.add(1);
                    }
                }
            }
            let environ_addr = core::ptr::addr_of!(platform::environ) as usize;
            eprintln!(
                "[relibc getenv-diag] looking up {:?}, &environ={:#x} environ={:p} null={} count={}",
                name_str, environ_addr, env_ptr, env_null, count
            );
            // Dump first 3 keys
            if !env_null {
                unsafe {
                    let mut p = env_ptr;
                    let mut i = 0usize;
                    while !(*p).is_null() && i < 3 {
                        let cstr = core::ffi::CStr::from_ptr(*p);
                        if let Ok(s) = core::str::from_utf8(cstr.to_bytes()) {
                            let key = s.split('=').next().unwrap_or(s);
                            eprintln!("[relibc getenv-diag]   env[{}]={}", i, key);
                        }
                        p = p.add(1);
                        i += 1;
                    }
                }
            }
        }
    }
    let result = unsafe { find_env(name) }
        .map(|val| val.1)
        .unwrap_or(ptr::null_mut());
    // Show result for DIAG lookups
    if let Ok(name_str) = core::str::from_utf8(name_cstr.to_bytes()) {
        if name_str.starts_with("DIAG") {
            eprintln!(
                "[relibc getenv-diag] result for {:?}: {:p} (null={})",
                name_str, result, result.is_null()
            );
        }
    }
    result
}"""

if OLD in content:
    content = content.replace(OLD, NEW)
    print("Patched getenv() with DIAG diagnostic")
else:
    print("ERROR: could not find getenv() to patch!")
    sys.exit(1)

with open("src/header/stdlib/mod.rs", "w") as f:
    f.write(content)
