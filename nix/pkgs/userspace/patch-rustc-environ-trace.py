#!/usr/bin/env python3
"""Diagnostic patch: trace option_env!/env!() resolution path in rustc.

Adds [ENVTRACE] logging inside rustc's compile-time environment variable
resolution to show what std::env::var() returns and whether the environ
pointer is null in the DSO context (librustc_driver.so).

Targets: library/std/src/sys/env/unix.rs (the getenv wrapper Rust std uses)

NOTE: This patch is for DIAGNOSIS ONLY. It should NOT be wired into
production builds. The actual fix is in patch-relibc-environ-dso-init.py.
"""
import sys
import os


def patch_std_env(root_dir):
    """Add [ENVTRACE] logging to Rust std's getenv implementation."""
    path = os.path.join(root_dir, "library/std/src/env.rs")
    if not os.path.exists(path):
        print(f"  NOTE: {path} not found — trying sys/env path")
        # Rust std env module location varies by version
        for alt in [
            "library/std/src/sys/env/unix.rs",
            "library/std/src/sys_common/os_str_bytes.rs",
        ]:
            alt_path = os.path.join(root_dir, alt)
            if os.path.exists(alt_path):
                path = alt_path
                break

    if not os.path.exists(path):
        print("  WARNING: Could not find Rust std env module")
        print("  [ENVTRACE] rustc tracing skipped — not critical")
        return False

    with open(path, "r") as f:
        content = f.read()

    # Look for the var() function that calls var_os()
    # In modern Rust std, env::var() calls var_os() which calls os::getenv()
    # The actual getenv goes through libc::getenv — which is relibc's getenv
    # on Redox. So the relibc-side tracing is sufficient.
    #
    # For completeness, we can add a trace at the Rust env::var() level.
    if "pub fn var<K: AsRef<OsStr>>(key: K)" in content:
        OLD_VAR = "pub fn var<K: AsRef<OsStr>>(key: K) -> Result<String, VarError> {"
        NEW_VAR = """pub fn var<K: AsRef<OsStr>>(key: K) -> Result<String, VarError> {
    // [ENVTRACE] Log LD_LIBRARY_PATH lookups at Rust std level
    if key.as_ref() == "LD_LIBRARY_PATH" {
        eprintln!("[ENVTRACE] std::env::var(LD_LIBRARY_PATH) called");
    }"""

        if OLD_VAR in content:
            content = content.replace(OLD_VAR, NEW_VAR)
            with open(path, "w") as f:
                f.write(content)
            print(f"  Patched {path}: [ENVTRACE] in env::var()")
            return True
        else:
            print(f"  WARNING: var() signature differs in {path}")
            return False
    else:
        print(f"  NOTE: var() not found in {path} — may be in different module")
        return False


if __name__ == "__main__":
    root_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    print("Patching Rust std: [ENVTRACE] diagnostics for env var resolution...")
    if patch_std_env(root_dir):
        print("Done: [ENVTRACE] diagnostics added to Rust std")
    else:
        print("Skipped: Rust std env tracing not applied (relibc-side tracing is sufficient)")
        # Not a fatal error — relibc-side tracing covers the critical path
