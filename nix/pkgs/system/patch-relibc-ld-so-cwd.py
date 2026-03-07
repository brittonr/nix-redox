#!/usr/bin/env python3
"""Patch ld_so to inject CWD into shared libraries.

Root cause: Each shared library (.so) that statically links relibc has its own
copy of the path::CWD static, initialized to None. When DSO code opens a file
with a relative path, canonicalize_using_cwd(None, "src/main.rs") returns None
→ ENOENT. Absolute paths work because they bypass CWD entirely.

The ld_so already injects ns_fd and proc_fd into DSOs via __relibc_init_*
symbols. This patch adds the same mechanism for CWD:

1. redox-rt/src/lib.rs:  Add __relibc_init_cwd_ptr and __relibc_init_cwd_len statics
2. src/ld_so/linker.rs:  Inject CWD from main binary into each DSO during run_init()
3. src/platform/redox/path.rs:  Lazy-init CWD from injected values when CWD is None

This removes the need for the rustc-abs wrapper that converts relative paths
to absolute before exec()ing the real rustc.
"""

import sys
import os

base = sys.argv[1] if len(sys.argv) > 1 else "."

# ═══════════════════════════════════════════════════════════════════════
# Part 1: Add __relibc_init_cwd_ptr and __relibc_init_cwd_len to redox-rt
# ═══════════════════════════════════════════════════════════════════════

rt_path = os.path.join(base, "redox-rt/src/lib.rs")
with open(rt_path, "r") as f:
    content = f.read()

if "__relibc_init_cwd_ptr" in content:
    print(f"  {rt_path}: __relibc_init_cwd_ptr already present, skipping")
else:
    # Insert after __relibc_init_proc_fd declaration
    anchor = """/// Process fd injected by ld_so for shared libraries.
#[used]
#[unsafe(no_mangle)]
pub static mut __relibc_init_proc_fd: usize = usize::MAX;"""

    replacement = anchor + """

/// CWD string pointer injected by ld_so for shared libraries.
/// When a DSO's path::CWD is None, it falls back to this value.
#[used]
#[unsafe(no_mangle)]
pub static mut __relibc_init_cwd_ptr: usize = 0;

/// CWD string length injected by ld_so for shared libraries.
#[used]
#[unsafe(no_mangle)]
pub static mut __relibc_init_cwd_len: usize = 0;"""

    if anchor in content:
        content = content.replace(anchor, replacement)
        with open(rt_path, "w") as f:
            f.write(content)
        print(f"  Patched {rt_path}: added __relibc_init_cwd_ptr/len statics")
    else:
        print(f"  ERROR: could not find __relibc_init_proc_fd anchor in {rt_path}")
        sys.exit(1)

# ═══════════════════════════════════════════════════════════════════════
# Part 2: Inject CWD in linker.rs run_init()
# ═══════════════════════════════════════════════════════════════════════

linker_path = os.path.join(base, "src/ld_so/linker.rs")
with open(linker_path, "r") as f:
    content = f.read()

if "__relibc_init_cwd_ptr" in content:
    print(f"  {linker_path}: CWD injection already present, skipping")
else:
    # Insert CWD injection after proc_fd injection, before obj.run_init()
    old_run_init = """            if let Some((symbol, _)) = obj.get_sym("__relibc_init_proc_fd") {
                let proc_fd = redox_rt::current_proc_fd().as_raw_fd();
                unsafe {
                    symbol.as_ptr().cast::<usize>().write(proc_fd);
                }
            }
        }

        obj.run_init();"""

    new_run_init = """            if let Some((symbol, _)) = obj.get_sym("__relibc_init_proc_fd") {
                let proc_fd = redox_rt::current_proc_fd().as_raw_fd();
                unsafe {
                    symbol.as_ptr().cast::<usize>().write(proc_fd);
                }
            }

            // Inject CWD into the DSO so relative path resolution works.
            // Each DSO has its own path::CWD static (initialized to None).
            // Without this injection, open("src/main.rs") returns ENOENT.
            if let Some((ptr_sym, _)) = obj.get_sym("__relibc_init_cwd_ptr") {
                if let Some((len_sym, _)) = obj.get_sym("__relibc_init_cwd_len") {
                    if let Some(cwd) = crate::platform::path::clone_cwd() {
                        let cwd_leaked = alloc::boxed::Box::leak(cwd);
                        unsafe {
                            ptr_sym.as_ptr().cast::<usize>().write(cwd_leaked.as_ptr() as usize);
                            len_sym.as_ptr().cast::<usize>().write(cwd_leaked.len());
                        }
                    }
                }
            }
        }

        obj.run_init();"""

    if old_run_init in content:
        content = content.replace(old_run_init, new_run_init)
        with open(linker_path, "w") as f:
            f.write(content)
        print(f"  Patched {linker_path}: added CWD injection in run_init()")
    else:
        print(f"  ERROR: could not find run_init proc_fd pattern in {linker_path}")
        # Show context for debugging
        if "__relibc_init_proc_fd" in content:
            idx = content.index("__relibc_init_proc_fd")
            ctx = content[idx:idx+400]
            print(f"  Context around __relibc_init_proc_fd:\n{ctx}")
        sys.exit(1)

# ═══════════════════════════════════════════════════════════════════════
# Part 3: Lazy-init CWD from injected values in path.rs
# ═══════════════════════════════════════════════════════════════════════

path_path = os.path.join(base, "src/platform/redox/path.rs")
with open(path_path, "r") as f:
    content = f.read()

if "__relibc_init_cwd_ptr" in content:
    print(f"  {path_path}: CWD fallback already present, skipping")
else:
    # Modify open() to check injected CWD when CWD is None.
    # The open() function is the main entry point for all file operations.
    # We intercept at the canonicalize_with_cwd_internal call inside open().
    #
    # The key line in open() is:
    #   let canon = canonicalize_with_cwd_internal(CWD.lock().as_deref(), path)?;
    #
    # We add a fallback: if CWD.lock() is None, try the injected CWD.

    old_open = """pub fn open(path: &str, flags: usize) -> Result<usize> {
    // TODO: SYMLOOP_MAX
    const MAX_LEVEL: usize = 64;

    let mut resolve_buf = [0_u8; 4096];
    let mut path = path;

    for _ in 0..MAX_LEVEL {
        let canon = canonicalize_with_cwd_internal(CWD.lock().as_deref(), path)?;"""

    new_open = """pub fn open(path: &str, flags: usize) -> Result<usize> {
    // TODO: SYMLOOP_MAX
    const MAX_LEVEL: usize = 64;

    let mut resolve_buf = [0_u8; 4096];
    let mut path = path;

    for _ in 0..MAX_LEVEL {
        let cwd_val = {
            let guard = CWD.lock();
            match guard.as_deref() {
                Some(c) => Some(alloc::string::String::from(c)),
                None => get_injected_cwd(),
            }
        };
        let canon = canonicalize_with_cwd_internal(cwd_val.as_deref(), path)?;"""

    if old_open in content:
        content = content.replace(old_open, new_open)
    else:
        print(f"  ERROR: could not find open() pattern in {path_path}")
        sys.exit(1)

    # Also patch canonicalize() which is used by chdir and other callers
    old_canonicalize = """pub fn canonicalize(path: &str) -> Result<String> {
    let _siglock = tmp_disable_signals();
    let cwd_guard = CWD.lock();
    canonicalize_with_cwd_internal(cwd_guard.as_deref(), path)
}"""

    new_canonicalize = """pub fn canonicalize(path: &str) -> Result<String> {
    let _siglock = tmp_disable_signals();
    let cwd_guard = CWD.lock();
    let cwd = match cwd_guard.as_deref() {
        Some(c) => Some(alloc::string::String::from(c)),
        None => {
            drop(cwd_guard);
            get_injected_cwd()
        }
    };
    canonicalize_with_cwd_internal(cwd.as_deref(), path)
}"""

    if old_canonicalize in content:
        content = content.replace(old_canonicalize, new_canonicalize)
    else:
        print(f"  WARNING: could not find canonicalize() pattern in {path_path}")

    # Add the get_injected_cwd() helper function after clone_cwd()
    clone_cwd_fn = """pub fn clone_cwd() -> Option<Box<str>> {
    let _siglock = tmp_disable_signals();
    CWD.lock().clone()
}"""

    clone_cwd_with_helper = """pub fn clone_cwd() -> Option<Box<str>> {
    let _siglock = tmp_disable_signals();
    CWD.lock().clone()
}

/// Read CWD from ld_so-injected statics (for shared libraries).
/// Each DSO has its own CWD static initialized to None. The dynamic
/// linker injects the main binary's CWD via __relibc_init_cwd_ptr/len
/// so relative path resolution works in DSO code.
fn get_injected_cwd() -> Option<alloc::string::String> {
    unsafe {
        let ptr = redox_rt::__relibc_init_cwd_ptr;
        let len = redox_rt::__relibc_init_cwd_len;
        if ptr != 0 && len != 0 {
            let bytes = core::slice::from_raw_parts(ptr as *const u8, len);
            if let Ok(s) = core::str::from_utf8(bytes) {
                // Initialize our CWD from the injected value so subsequent
                // calls don't need to check the injected statics again.
                set_cwd_manual(s.into());
                return Some(alloc::string::String::from(s));
            }
        }
    }
    None
}"""

    if clone_cwd_fn in content:
        content = content.replace(clone_cwd_fn, clone_cwd_with_helper)
    else:
        print(f"  ERROR: could not find clone_cwd() pattern in {path_path}")
        sys.exit(1)

    with open(path_path, "w") as f:
        f.write(content)
    print(f"  Patched {path_path}: added CWD fallback from ld_so-injected statics")

print("  CWD injection patch complete (3 files)")
