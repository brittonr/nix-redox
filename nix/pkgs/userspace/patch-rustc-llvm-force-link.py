#!/usr/bin/env python3
"""Patch compiler/rustc_llvm/build.rs to force-include LLVM X86 target symbols.

When statically linking LLVM into librustc_driver.so, the linker dead-strips
the X86 backend (registered via constructors) because nothing directly references
the registration functions. This causes "no targets are registered" at runtime.

Fix: emit cargo:rustc-link-arg=-Wl,-u,<symbol> for each X86 init function,
forcing the linker to include the object files containing them.
"""

path = "compiler/rustc_llvm/build.rs"
with open(path) as f:
    content = f.read()

force_link_code = """
    // Force-include LLVM X86 target registration (Redox cross-compile fix).
    // Without these, static linking dead-strips the X86 backend constructors.
    let force_symbols = [
        "LLVMInitializeX86Target",
        "LLVMInitializeX86TargetInfo",
        "LLVMInitializeX86TargetMC",
        "LLVMInitializeX86AsmPrinter",
        "LLVMInitializeX86AsmParser",
    ];
    for sym in &force_symbols {
        println!("cargo:rustc-link-arg=-Wl,-u,{sym}");
    }

"""

marker = "// Some LLVM linker flags (-L and -l) may be needed even when linking"
if marker in content:
    content = content.replace(marker, force_link_code + "    " + marker)
    with open(path, 'w') as f:
        f.write(content)
    print(f"  Patched {path}: added force-link symbols for X86 target")
else:
    print(f"  WARNING: could not find marker in {path}")
    import sys
    sys.exit(1)
