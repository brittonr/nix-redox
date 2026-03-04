#!/usr/bin/env python3
"""Patch the Rust bootstrap to add -Wl,-u flags for LLVM X86 target symbols.

When statically linking LLVM into librustc_driver.so for cross-compiled Redox,
the linker dead-strips the X86 backend registration functions (they're only
referenced via constructors, not direct calls). This causes "no targets are
registered" at runtime.

Fix: add -Clink-args=-Wl,-u,<symbol> to the bootstrap's RUSTFLAGS for the
Redox target, forcing the linker to include these object files.
"""
import os, glob

# Find the builder.rs file
candidates = glob.glob("src/bootstrap/src/core/builder/*.rs")
path = None
for c in candidates:
    with open(c) as f:
        if "-Clink-args=-Wl,-z,origin" in f.read():
            path = c
            break

if not path:
    print("  WARNING: could not find bootstrap builder.rs with rpath logic")
    exit(1)

with open(path) as f:
    content = f.read()

# Insert force-link flags right after the rpath block
old = '''            if let Some(rpath) = rpath {
                self.rustflags.arg(&format!("-Clink-args={rpath}"));
            }'''

new = '''            if let Some(rpath) = rpath {
                self.rustflags.arg(&format!("-Clink-args={rpath}"));
            }

            // Force-include LLVM X86 target registration symbols (Redox cross-compile fix).
            // Static linking of LLVM into librustc_driver.so dead-strips the X86 backend
            // because registration functions are only called via constructors.
            if target.contains("redox") {
                for sym in [
                    "LLVMInitializeX86Target",
                    "LLVMInitializeX86TargetInfo",
                    "LLVMInitializeX86TargetMC",
                    "LLVMInitializeX86AsmPrinter",
                    "LLVMInitializeX86AsmParser",
                ] {
                    self.rustflags.arg(&format!("-Clink-args=-Wl,-u,{sym}"));
                }
                // Redox kernel gives the main thread a very small stack (~8KB).
                // rustc needs at least 8MB for session setup before spawning the
                // worker thread. Set PT_GNU_STACK memsiz so the kernel allocates more.
                self.rustflags.arg("-Clink-args=-Wl,-z,stack-size=8388608");
            }'''

if old in content:
    content = content.replace(old, new)
    with open(path, 'w') as f:
        f.write(content)
    print(f"  Patched {path}: added force-link -u flags for Redox X86 target")
else:
    print(f"  WARNING: could not find rpath block in {path}")
    exit(1)
