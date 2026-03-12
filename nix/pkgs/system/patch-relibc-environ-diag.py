#!/usr/bin/env python3
"""Temporary diagnostic patch: trace environ propagation in init_array().

Adds eprintln! output to init_array() in src/start.rs to show:
- Whether platform::environ is null when init_array runs
- Whether __relibc_init_environ was set by ld_so's run_init
- The final state after the assignment
"""
import sys

with open("src/start.rs", "r") as f:
    content = f.read()

OLD_INIT = """\
    unsafe {
        if platform::environ.is_null() {
            platform::environ = __relibc_init_environ;
        }
    }"""

NEW_INIT = """\
    unsafe {
        let before_environ = core::ptr::addr_of!(platform::environ).read();
        let injected = core::ptr::addr_of!(__relibc_init_environ).read();

        // Only print diagnostics when ld_so injected a value (DSO-linked binaries).
        // Static binaries have __relibc_init_environ=null, skip to reduce boot spam.
        if !injected.is_null() {
            let injected_count = {
                let mut c = 0usize;
                let mut p = injected;
                while !(*p).is_null() {
                    c += 1;
                    p = p.add(1);
                }
                c
            };
            eprintln!(
                "[relibc init_array environ-diag] platform::environ={:p} null={}, \
                 __relibc_init_environ={:p} count={}",
                before_environ, before_environ.is_null(),
                injected, injected_count,
            );
        }

        if core::ptr::addr_of!(platform::environ).read().is_null() {
            platform::environ = injected;
            if !injected.is_null() {
                eprintln!(
                    "[relibc init_array environ-diag] ASSIGNED: platform::environ now={:p}",
                    core::ptr::addr_of!(platform::environ).read(),
                );
            }
        } else if !injected.is_null() {
            eprintln!(
                "[relibc init_array environ-diag] SKIPPED: platform::environ already {:p}",
                before_environ,
            );
        }
    }"""

if OLD_INIT in content:
    content = content.replace(OLD_INIT, NEW_INIT)
    print("Patched init_array() with environ diagnostics")
else:
    print("ERROR: could not find init_array() environ block in src/start.rs!")
    sys.exit(1)

with open("src/start.rs", "w") as f:
    f.write(content)
