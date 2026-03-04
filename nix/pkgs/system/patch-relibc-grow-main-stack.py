#!/usr/bin/env python3
"""Patch relibc's relibc_start_v1 to run main() on a larger stack.

The Redox kernel gives the main thread only ~8KB of stack, which is far too
small for compiler-scale programs (clang, rustc, lld) that need megabytes of
stack for recursive AST processing and code generation. The kernel does NOT
support demand-paging for anonymous mmap regions, so the stack can't grow
dynamically.

Fix: Before calling main(), allocate an 8MB stack via mmap, pre-fault all
pages, switch RSP to the new stack, and call main() from there. This makes
ALL statically-linked Redox binaries work regardless of stack requirements.

The implementation uses inline assembly for the stack switch (x86_64 only):
  1. Save old RSP in callee-saved RBX
  2. Switch RSP to the top of the new stack (16-byte aligned)
  3. Call main(argc, argv, envp) via function pointer
  4. Restore old RSP from RBX
  5. Pass main()'s return value to exit()

Fallback: if mmap fails, main() runs on the original kernel stack (8KB).
"""

path = "src/start.rs"
with open(path) as f:
    content = f.read()

# Add the sys_mman import at the top of the imports
old_imports = """use crate::{
    ALLOCATOR,
    header::{libgen, stdio, stdlib},"""

new_imports = """use crate::{
    ALLOCATOR,
    header::{libgen, stdio, stdlib, sys_mman},"""

if old_imports in content:
    content = content.replace(old_imports, new_imports)
    print(f"  Patched {path}: added sys_mman import")
else:
    print(f"  WARNING: imports already modified or different in {path}")

# Replace the direct main() call with a stack-growing wrapper
old_main_call = """    // not argv or envp, because programs like bash try to modify this *const* pointer :|
    unsafe { stdlib::exit(main(argc, platform::argv, platform::environ)) };

    unreachable!();
}"""

new_main_call = r"""    // Grow the main thread stack before calling main().
    // The Redox kernel only gives ~8KB to the initial thread, which is
    // too small for compilers and other stack-heavy programs. Allocate
    // an 8MB stack via mmap, pre-fault all pages (Redox doesn't reliably
    // demand-page anonymous mappings), and run main() on the new stack.
    #[cfg(target_arch = "x86_64")]
    {
        const NEW_STACK_SIZE: usize = 8 * 1024 * 1024; // 8 MB

        let stack_ptr = unsafe {
            sys_mman::mmap(
                core::ptr::null_mut(),
                NEW_STACK_SIZE,
                sys_mman::PROT_READ | sys_mman::PROT_WRITE,
                sys_mman::MAP_PRIVATE | sys_mman::MAP_ANONYMOUS,
                -1,
                0,
            )
        };

        if stack_ptr != sys_mman::MAP_FAILED {
            // Pre-fault every page so the kernel allocates physical memory.
            // Without this, stack growth may cause a kernel trap instead of
            // a page fault that allocates a new physical page.
            unsafe {
                let base = stack_ptr as *mut u8;
                let mut offset = 0;
                while offset < NEW_STACK_SIZE {
                    core::ptr::write_volatile(base.add(offset), 0);
                    offset += 4096;
                }
            }

            // Stack grows downward. Align top to 16 bytes for SysV ABI.
            // The `call` instruction will push 8 bytes (return address),
            // making RSP = 16n+8 at the callee entry — as the ABI requires.
            let new_rsp = (stack_ptr as usize + NEW_STACK_SIZE) & !15;

            let main_fn_ptr = main as usize;
            let exit_code: i32;

            // Switch RSP to the new stack, call main(), switch back.
            // RBX is callee-saved, so main() preserves it for us.
            unsafe {
                core::arch::asm!(
                    "push rbx",
                    "mov rbx, rsp",
                    "mov rsp, {new_rsp}",
                    "call {main_fn}",
                    "mov rsp, rbx",
                    "pop rbx",
                    new_rsp = in(reg) new_rsp,
                    main_fn = in(reg) main_fn_ptr,
                    in("rdi") argc as i64,
                    in("rsi") platform::argv as usize,
                    in("rdx") platform::environ as usize,
                    lateout("rax") exit_code,
                    out("rcx") _,
                    out("r8") _,
                    out("r9") _,
                    out("r10") _,
                    out("r11") _,
                );
            }

            unsafe { stdlib::exit(exit_code) };
        }
        // mmap failed — fall through to run main() on the original stack
    }

    // not argv or envp, because programs like bash try to modify this *const* pointer :|
    unsafe { stdlib::exit(main(argc, platform::argv, platform::environ)) };

    unreachable!();
}"""

if old_main_call in content:
    content = content.replace(old_main_call, new_main_call)
    print(f"  Patched {path}: main() now runs on 8MB mmap'd stack")
else:
    print(f"  WARNING: could not find main() call pattern in {path}")
    # Try to show what we're looking for
    if "stdlib::exit(main(" in content:
        print(f"  Note: found stdlib::exit(main( but context differs")
    import sys
    sys.exit(1)

with open(path, 'w') as f:
    f.write(content)
