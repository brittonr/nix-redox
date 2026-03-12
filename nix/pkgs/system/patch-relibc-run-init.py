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

        // DEBUG: trace environ injection into DSOs
        let environ_ptr = unsafe { core::ptr::addr_of!(platform::environ).read() };
        let environ_is_null = environ_ptr.is_null();
        let environ_count = if environ_is_null {
            0usize
        } else {
            let mut count = 0usize;
            unsafe {
                let mut p = environ_ptr;
                while !(*p).is_null() {
                    count += 1;
                    p = p.add(1);
                }
            }
            count
        };

        // Accept any binding
        match obj.get_sym("__relibc_init_environ") {
            Some((symbol, binding)) => {
                eprintln!(
                    "[ld.so environ-diag] FOUND __relibc_init_environ in DSO (binding={:?}), \
                     ld_so environ={:p} null={} count={}, writing to sym addr={:p}",
                    binding, environ_ptr, environ_is_null, environ_count,
                    symbol.as_ptr()
                );
                unsafe {
                    symbol
                        .as_ptr()
                        .cast::<*mut *mut c_char>()
                        .write(environ_ptr);
                }
                // Verify write
                let readback = unsafe {
                    symbol.as_ptr().cast::<*mut *mut c_char>().read()
                };
                eprintln!(
                    "[ld.so environ-diag] readback after write: {:p} (match={})",
                    readback, readback == environ_ptr
                );
            }
            None => {
                eprintln!(
                    "[ld.so environ-diag] __relibc_init_environ NOT FOUND in DSO, \
                     ld_so environ={:p} null={} count={}",
                    environ_ptr, environ_is_null, environ_count
                );
            }
        }

        // Inject process fds into DSO statics BEFORE calling .init_array.
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
