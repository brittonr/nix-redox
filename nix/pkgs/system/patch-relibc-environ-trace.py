#!/usr/bin/env python3
"""Diagnostic patch: trace environ propagation with [ENVTRACE] prefix.

Adds targeted tracing to three critical points in the environ chain:
1. relibc_start_v1 — after environ is set from kernel envp
2. init_array — when DSO/main binary tries to init environ from __relibc_init_environ
3. getenv — when environ fallback from __relibc_init_environ triggers

All output uses [ENVTRACE] prefix for easy grepping in test logs.

NOTE: This patch is for DIAGNOSIS ONLY. It should NOT be wired into
production builds. The actual fix is in patch-relibc-environ-dso-init.py.
"""
import sys

# ── Part 1: Trace relibc_start_v1 environ setup ──

with open("src/start.rs", "r") as f:
    content = f.read()

OLD_START = """\
    // We check for NULL here since ld.so might already have initialized it for us, and we don't
    // want to overwrite it if constructors in .init_array of dependency libraries have called
    // setenv.
    if unsafe { platform::environ }.is_null() {
        // Set up envp
        let envp = sp.envp();
        let mut len = 0;
        while !(unsafe { *envp.add(len) }).is_null() {
            len += 1;
        }
        unsafe { platform::OUR_ENVIRON.unsafe_set(copy_string_array(envp, len)) };
        unsafe { platform::environ = platform::OUR_ENVIRON.unsafe_mut().as_mut_ptr() };
    }

    let auxvs"""

NEW_START = """\
    // We check for NULL here since ld.so might already have initialized it for us, and we don't
    // want to overwrite it if constructors in .init_array of dependency libraries have called
    // setenv.
    let _environ_was_null = unsafe { platform::environ }.is_null();
    if _environ_was_null {
        // Set up envp
        let envp = sp.envp();
        let mut len = 0;
        while !(unsafe { *envp.add(len) }).is_null() {
            len += 1;
        }
        unsafe { platform::OUR_ENVIRON.unsafe_set(copy_string_array(envp, len)) };
        unsafe { platform::environ = platform::OUR_ENVIRON.unsafe_mut().as_mut_ptr() };
    }
    // [ENVTRACE] relibc_start_v1: report environ state after setup
    {
        let env_ptr = unsafe { core::ptr::addr_of!(platform::environ).read() };
        let init_ptr = unsafe { core::ptr::addr_of!(__relibc_init_environ).read() };
        let env_count = if env_ptr.is_null() { 0 } else {
            let mut c = 0usize;
            unsafe { let mut p = env_ptr; while !(*p).is_null() { c += 1; p = p.add(1); } }
            c
        };
        eprintln!(
            "[ENVTRACE] relibc_start_v1: was_null={} environ={:p} count={} __relibc_init_environ={:p}",
            _environ_was_null, env_ptr, env_count, init_ptr,
        );
    }

    let auxvs"""

if OLD_START in content:
    content = content.replace(OLD_START, NEW_START)
    print("Patched relibc_start_v1 with [ENVTRACE] diagnostics")
else:
    # Check if environ-diag.py already modified init_array (different function, should be fine)
    if "relibc_start_v1" not in content:
        print("ERROR: could not find relibc_start_v1 in src/start.rs!")
        sys.exit(1)
    print("ERROR: could not find environ setup block in relibc_start_v1!")
    print("  (another patch may have modified this section)")
    sys.exit(1)

with open("src/start.rs", "w") as f:
    f.write(content)

# ── Part 2: Trace getenv fallback ──

with open("src/header/stdlib/mod.rs", "r") as f:
    content = f.read()

# The dso-environ patch adds a self-init block at the top of getenv.
# We add an [ENVTRACE] log AFTER that block, only for LD_LIBRARY_PATH lookups.
# Look for the getenv signature (before or after dso-environ patch).
OLD_GETENV = """pub unsafe extern "C" fn getenv(name: *const c_char) -> *mut c_char {
    unsafe { find_env(name) }"""

if OLD_GETENV in content:
    NEW_GETENV = """pub unsafe extern "C" fn getenv(name: *const c_char) -> *mut c_char {
    // [ENVTRACE] log LD_LIBRARY_PATH lookups to trace DSO environ state
    {
        let n = unsafe { core::ffi::CStr::from_ptr(name) };
        if let Ok(s) = core::str::from_utf8(n.to_bytes()) {
            if s == "LD_LIBRARY_PATH" {
                let env_ptr = unsafe { core::ptr::addr_of!(platform::environ).read() };
                eprintln!(
                    "[ENVTRACE] getenv(LD_LIBRARY_PATH): environ={:p} null={}",
                    env_ptr, env_ptr.is_null(),
                );
            }
        }
    }
    unsafe { find_env(name) }"""
    content = content.replace(OLD_GETENV, NEW_GETENV)
    print("Patched getenv() with [ENVTRACE] for LD_LIBRARY_PATH lookups")
else:
    print("NOTE: getenv() signature differs (dso-environ or getenv-diag patch may be active)")
    print("  Skipping getenv [ENVTRACE] — not critical for diagnosis")

with open("src/header/stdlib/mod.rs", "w") as f:
    f.write(content)

print("Done: [ENVTRACE] diagnostics added to relibc")
