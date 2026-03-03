#!/usr/bin/env python3
"""Patch redox-rt to add process state injection for shared libraries.

Adds __relibc_init_ns_fd / __relibc_init_proc_fd statics (data symbols,
not renamed by renamesyms.sh) and modifies current_namespace_fd() and
static_proc_info() to lazily initialize from injected values."""
import sys

with open("redox-rt/src/lib.rs", "r") as f:
    content = f.read()

# ── Patch 1: current_namespace_fd() ─────────────────────────────────

OLD_NS = """\
#[inline]
pub fn current_namespace_fd() -> usize {
    DYNAMIC_PROC_INFO
        .lock()
        .ns_fd
        .as_ref()
        .map(|g| g.as_raw_fd())
        .unwrap_or(usize::MAX)
}"""

NEW_NS = """\
/// Namespace fd injected by ld_so for shared libraries.
#[used]
#[unsafe(no_mangle)]
pub static mut __relibc_init_ns_fd: usize = usize::MAX;

/// Process fd injected by ld_so for shared libraries.
#[used]
#[unsafe(no_mangle)]
pub static mut __relibc_init_proc_fd: usize = usize::MAX;

#[inline]
pub fn current_namespace_fd() -> usize {
    // Check ld_so-injected ns_fd first (for shared libraries).
    let injected = unsafe { __relibc_init_ns_fd };
    if injected != usize::MAX {
        return injected;
    }
    DYNAMIC_PROC_INFO
        .lock()
        .ns_fd
        .as_ref()
        .map(|g| g.as_raw_fd())
        .unwrap_or(usize::MAX)
}"""

if OLD_NS in content:
    content = content.replace(OLD_NS, NEW_NS)
    print("Patched current_namespace_fd()")
else:
    print("ERROR: could not find current_namespace_fd()!")
    sys.exit(1)

# ── Patch 2: static_proc_info() — lazy init from injected proc_fd ──

OLD_SPI = """\
#[inline]
pub(crate) fn static_proc_info() -> &'static StaticProcInfo {
    unsafe { &*STATIC_PROC_INFO.get() }
}"""

NEW_SPI = """\
#[inline]
pub(crate) fn static_proc_info() -> &'static StaticProcInfo {
    unsafe {
        let info = &*STATIC_PROC_INFO.get();
        // If proc_fd is uninitialized, try lazy init from ld_so-injected value.
        // This runs before any threads exist, so no race condition.
        if info.proc_fd.is_none() {
            let injected = __relibc_init_proc_fd;
            if injected != usize::MAX {
                use crate::proc::{FdGuard, STATIC_PROC_INFO};
                if let Ok(new_fd) = syscall::dup(injected, b"") {
                    if let Ok(proc_fd) = FdGuard::new(new_fd).to_upper() {
                        if let Ok(metadata) = read_proc_meta(&proc_fd) {
                            STATIC_PROC_INFO.get().write(StaticProcInfo {
                                pid: metadata.pid,
                                proc_fd: Some(proc_fd),
                            });
                        }
                    }
                }
                return &*STATIC_PROC_INFO.get();
            }
        }
        info
    }
}"""

if OLD_SPI in content:
    content = content.replace(OLD_SPI, NEW_SPI)
    print("Patched static_proc_info()")
else:
    print("ERROR: could not find static_proc_info()!")
    sys.exit(1)

with open("redox-rt/src/lib.rs", "w") as f:
    f.write(content)
