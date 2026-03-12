#!/usr/bin/env python3
"""Patch ld_so run_init() to write namespace fd and proc fd into each loaded DSO's
__relibc_init_ns_fd / __relibc_init_proc_fd statics before calling .init_array."""
import sys

with open("src/ld_so/linker.rs", "r") as f:
    content = f.read()

OLD_FN = """\
    fn run_init(&self, obj: &DSO) {
        use crate::platform::{self, types::*};

        if let Some((symbol, SymbolBinding::Global)) = obj.get_sym("__relibc_init_environ") {
            unsafe {
                symbol
                    .as_ptr()
                    .cast::<*mut *mut c_char>()
                    .write(platform::environ);
            }
        }

        obj.run_init();
    }"""

NEW_FN = """\
    fn run_init(&self, obj: &DSO) {
        use crate::platform::{self, types::*};

        // Accept any binding — Rust's version scripts may export this as local
        // even when explicitly listed in global section.
        if let Some((symbol, _)) = obj.get_sym("__relibc_init_environ") {
            unsafe {
                symbol
                    .as_ptr()
                    .cast::<*mut *mut c_char>()
                    .write(platform::environ);
            }
        }

        // Inject process fds into DSO statics BEFORE calling .init_array.
        // The DSO's .init_array constructor (__relibc_dso_init) reads these
        // and initializes its STATIC_PROC_INFO and DYNAMIC_PROC_INFO.
        #[cfg(target_os = "redox")]
        {
            if let Some((symbol, _)) = obj.get_sym("__relibc_init_ns_fd") {
                let ns_fd = redox_rt::current_namespace_fd();
                if ns_fd != usize::MAX {
                    unsafe {
                        symbol.as_ptr().cast::<usize>().write(ns_fd);
                    }
                }
            }
            if let Some((symbol, _)) = obj.get_sym("__relibc_init_proc_fd") {
                let proc_fd = redox_rt::current_proc_fd().as_raw_fd();
                unsafe {
                    symbol.as_ptr().cast::<usize>().write(proc_fd);
                }
            }
        }

        obj.run_init();
    }"""

if OLD_FN in content:
    content = content.replace(OLD_FN, NEW_FN)
    print("Patched run_init() to inject __relibc_init_ns_fd and __relibc_init_proc_fd")
else:
    print("ERROR: could not find run_init() to patch!")
    sys.exit(1)

with open("src/ld_so/linker.rs", "w") as f:
    f.write(content)
