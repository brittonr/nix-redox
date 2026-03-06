#!/usr/bin/env python3
"""Neutralize build scripts that fork rustc for version detection.

On Redox OS, build scripts that call Command::new(rustc) hang due to
the fork+exec+pipe issue with subprocess chains. This script replaces
those build scripts with pre-computed equivalents for rustc 1.92.0-nightly.
"""

import os
import json
import sys

vendor = sys.argv[1]

# Build script replacements for rustc 1.92.0-nightly (2025-10-02)
neutralized = {
    # rustversion: writes version.rs to OUT_DIR, included via include!()
    "rustversion": (
        'fn main() {\n'
        '    use std::env;\n'
        '    use std::fs;\n'
        '    use std::path::PathBuf;\n'
        '    let out_dir = PathBuf::from(env::var_os("OUT_DIR").unwrap());\n'
        '    let code = "pub const MINOR: u32 = 92;\\n'
        'pub const PATCH: u32 = 0;\\n'
        'pub const CHANNEL: Channel = Channel::Nightly;\\n'
        'pub enum Channel { Stable, Beta, Nightly, Dev }\\n";\n'
        '    fs::write(out_dir.join("version.rs"), code).unwrap();\n'
        '}\n'
    ),

    # thiserror: writes private.rs to OUT_DIR + probe compile
    "thiserror": (
        'fn main() {\n'
        '    use std::env;\n'
        '    use std::fs;\n'
        '    use std::path::PathBuf;\n'
        '    println!("cargo:rustc-check-cfg=cfg(error_generic_member_access)");\n'
        '    println!("cargo:rustc-check-cfg=cfg(thiserror_nightly_testing)");\n'
        '    println!("cargo:rustc-check-cfg=cfg(thiserror_no_backtrace_type)");\n'
        '    let out_dir = PathBuf::from(env::var_os("OUT_DIR").unwrap());\n'
        '    let patch_version = env::var("CARGO_PKG_VERSION_PATCH").unwrap();\n'
        '    let module = format!("#[doc(hidden)]\\npub mod __private{} {{\\n'
        '    #[doc(hidden)]\\n    pub use crate::private::*;\\n}}\\n", patch_version);\n'
        '    fs::write(out_dir.join("private.rs"), module).unwrap();\n'
        '    println!("cargo:rustc-cfg=error_generic_member_access");\n'
        '}\n'
    ),

    # serde: version detection for cfg flags (no OUT_DIR writes)
    "serde": (
        'fn main() {\n'
        '    println!("cargo:rustc-check-cfg=cfg(no_core_cstr)");\n'
        '    println!("cargo:rustc-check-cfg=cfg(no_core_error)");\n'
        '    println!("cargo:rustc-check-cfg=cfg(no_core_net)");\n'
        '    println!("cargo:rustc-check-cfg=cfg(no_core_num_saturating)");\n'
        '    println!("cargo:rustc-check-cfg=cfg(no_diagnostic_namespace)");\n'
        '    println!("cargo:rustc-check-cfg=cfg(no_serde_derive)");\n'
        '    println!("cargo:rustc-check-cfg=cfg(no_std_atomic)");\n'
        '    println!("cargo:rustc-check-cfg=cfg(no_std_atomic64)");\n'
        '    println!("cargo:rustc-check-cfg=cfg(no_target_has_atomic)");\n'
        '}\n'
    ),

    # syn: version detection (no OUT_DIR writes)
    "syn": 'fn main() {}\n',

    # quote: version detection (no OUT_DIR writes)
    "quote": 'fn main() {}\n',

    # libc: version detection (no OUT_DIR writes)
    "libc": (
        'fn main() {\n'
        '    println!("cargo:rustc-check-cfg=cfg(libc_deny_warnings)");\n'
        '    println!("cargo:rustc-check-cfg=cfg(libc_thread_local)");\n'
        '}\n'
    ),

    # crc32fast: version detection (no OUT_DIR writes)
    "crc32fast": (
        'fn main() {\n'
        '    println!("cargo:rustc-cfg=crc32fast_stdarchx86");\n'
        '}\n'
    ),

    # getrandom: cfg detection
    "getrandom": 'fn main() {}\n',

    # httparse: SIMD detection
    "httparse": (
        'fn main() {\n'
        '    println!("cargo:rustc-cfg=httparse_simd");\n'
        '}\n'
    ),

    # rustix: cfg detection (uses libc backend on non-Linux)
    "rustix": 'fn main() {}\n',
}

for crate_prefix, build_rs_content in neutralized.items():
    for entry in os.listdir(vendor):
        if entry.startswith(crate_prefix + "-") or entry == crate_prefix:
            crate_dir = os.path.join(vendor, entry)
            build_rs = os.path.join(crate_dir, "build.rs")
            build_dir_rs = os.path.join(crate_dir, "build", "build.rs")

            if os.path.exists(build_rs):
                with open(build_rs, 'w') as f:
                    f.write(build_rs_content)
                print(f"  Neutralized build.rs in {entry}")
            elif os.path.exists(build_dir_rs):
                with open(build_dir_rs, 'w') as f:
                    f.write(build_rs_content)
                print(f"  Neutralized build/build.rs in {entry}")

            # Update checksum (empty files hash)
            checksum_path = os.path.join(crate_dir, ".cargo-checksum.json")
            if os.path.exists(checksum_path):
                with open(checksum_path, 'r') as f:
                    cs = json.load(f)
                cs["files"] = {}
                with open(checksum_path, 'w') as f:
                    json.dump(cs, f)
