#!/usr/bin/env python3
"""Teach Redox kernel build.rs to use prebuilt trampoline blobs when nasm is absent.

Why:
- host cross-builds have nasm in nativeBuildInputs, so assembling from .asm stays preferred
- native Redox guest rebuilds currently lack a usable nasm package
- trampoline blobs are deterministic for the checked-in asm source

Patch shape:
1. import fs + io in build.rs
2. add build_trampoline() helper
3. replace x86/x86_64 inline nasm invocations with helper calls
"""

import os
import sys


def patch_file(path: str, old: str, new: str) -> None:
    with open(path, "r") as f:
        content = f.read()
    if old not in content:
        print(f"WARNING: patch target not found in {path}")
        print(f"  Looking for: {repr(old[:100])}...")
        return
    content = content.replace(old, new, 1)
    with open(path, "w") as f:
        f.write(content)
    print(f"  Patched {path}")


def main() -> None:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <kernel-src-dir>", file=sys.stderr)
        sys.exit(1)

    src_dir = sys.argv[1]
    build_rs = os.path.join(src_dir, "build.rs")

    patch_file(
        build_rs,
        "use std::{env, path::Path, process::Command};",
        "use std::{env, fs, io, path::Path, process::Command};",
    )

    patch_file(
        build_rs,
        "fn main() {",
        """fn build_trampoline(arch: &str, out_dir: &str) {
    let (asm_path, prebuilt_path) = match arch {
        \"x86\" => (\"src/asm/x86/trampoline.asm\", \"src/asm/x86/trampoline.bin\"),
        \"x86_64\" => (\"src/asm/x86_64/trampoline.asm\", \"src/asm/x86_64/trampoline.bin\"),
        _ => return,
    };

    println!(\"cargo::rerun-if-changed={asm_path}\");
    println!(\"cargo::rerun-if-changed={prebuilt_path}\");

    let out_path = format!(\"{}/trampoline\", out_dir);
    let use_prebuilt = env::var_os(\"REDOX_KERNEL_USE_PREBUILT_TRAMPOLINE\").is_some();
    if use_prebuilt {
        println!(\"cargo:warning=using prebuilt trampoline {}\", prebuilt_path);
        fs::copy(prebuilt_path, &out_path).expect(\"failed to copy prebuilt trampoline\");
        return;
    }

    match Command::new(\"nasm\")
        .arg(\"-f\")
        .arg(\"bin\")
        .arg(\"-o\")
        .arg(&out_path)
        .arg(asm_path)
        .status()
    {
        Ok(status) if status.success() => {}
        Ok(status) => panic!(\"nasm failed with exit status {}\", status),
        Err(err) if err.kind() == io::ErrorKind::NotFound => {
            println!(\"cargo:warning=nasm not found, using prebuilt trampoline {}\", prebuilt_path);
            fs::copy(prebuilt_path, &out_path).expect(\"failed to copy prebuilt trampoline\");
        }
        Err(err) => panic!(\"failed to run nasm: {err}\"),
    }
}

fn main() {""",
    )

    patch_file(
        build_rs,
        """        \"x86\" => {
            println!(\"cargo::rerun-if-changed=src/asm/x86/trampoline.asm\");

            let status = Command::new(\"nasm\")
                .arg(\"-f\")
                .arg(\"bin\")
                .arg(\"-o\")
                .arg(format!(\"{}/trampoline\", out_dir))
                .arg(\"src/asm/x86/trampoline.asm\")
                .status()
                .expect(\"failed to run nasm\");
            if !status.success() {
                panic!(\"nasm failed with exit status {}\", status);
            }
        }""",
        """        \"x86\" => {
            build_trampoline(\"x86\", &out_dir);
        }""",
    )

    patch_file(
        build_rs,
        """        \"x86_64\" => {
            println!(\"cargo::rerun-if-changed=src/asm/x86_64/trampoline.asm\");

            let status = Command::new(\"nasm\")
                .arg(\"-f\")
                .arg(\"bin\")
                .arg(\"-o\")
                .arg(format!(\"{}/trampoline\", out_dir))
                .arg(\"src/asm/x86_64/trampoline.asm\")
                .status()
                .expect(\"failed to run nasm\");
            if !status.success() {
                panic!(\"nasm failed with exit status {}\", status);
            }
        }""",
        """        \"x86_64\" => {
            build_trampoline(\"x86_64\", &out_dir);
        }""",
    )

    print("Kernel trampoline fallback patch applied")


if __name__ == "__main__":
    main()
