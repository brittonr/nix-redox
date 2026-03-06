#!/usr/bin/env python3
"""Patch ld_so's dso.rs to handle p_align=0 in ELF program headers.

When loading shared libraries (.so files), ld_so iterates all program headers
and computes voff = p_vaddr % p_align for EVERY header before checking p_type.
Non-PT_LOAD segments (PT_NOTE, PT_GNU_STACK, PT_GNU_RELRO) may have p_align=0,
which causes 'attempt to calculate the remainder with a divisor of zero' panic.

This is triggered when rustc tries to dlopen() a proc-macro .so file.

Fix: Guard p_align with max(p_align, 1) to treat 0-alignment as 1.
"""

import sys
import os

base = sys.argv[1] if len(sys.argv) > 1 else "."
dso_path = os.path.join(base, "src/ld_so/dso.rs")

with open(dso_path, 'r') as f:
    content = f.read()

# The buggy code computes voff/vaddr/vsize using p_align for ALL program headers,
# but p_align can be 0 for non-PT_LOAD segments.
old = """            for ph in elf.elf_program_headers() {
                let voff = ph.p_vaddr(endian) % ph.p_align(endian);
                let vaddr = (ph.p_vaddr(endian) - voff) as usize;
                let vsize = ((ph.p_memsz(endian) + voff) as usize)
                    .next_multiple_of(ph.p_align(endian) as usize);"""

new = """            for ph in elf.elf_program_headers() {
                // Guard against p_align=0 (valid per ELF spec for non-PT_LOAD segments
                // like PT_NOTE, PT_GNU_STACK, PT_GNU_RELRO). Treat 0 as 1 to avoid
                // division-by-zero in the modulo and next_multiple_of operations.
                let align = core::cmp::max(ph.p_align(endian), 1);
                let voff = ph.p_vaddr(endian) % align;
                let vaddr = (ph.p_vaddr(endian) - voff) as usize;
                let vsize = ((ph.p_memsz(endian) + voff) as usize)
                    .next_multiple_of(align as usize);"""

if old in content:
    content = content.replace(old, new)
    with open(dso_path, 'w') as f:
        f.write(content)
    print(f"  Patched {dso_path}: guard p_align=0 in program header iteration")
else:
    print(f"  ERROR: Could not find p_align pattern in {dso_path}")
    # Show what's there
    if "p_align" in content:
        import re
        matches = list(re.finditer(r'p_align\(endian\)', content))
        print(f"  Found {len(matches)} p_align references")
        for m in matches[:3]:
            start = max(0, m.start() - 80)
            end = min(len(content), m.end() + 80)
            print(f"  Context: ...{content[start:end]}...")
    sys.exit(1)
