#!/usr/bin/env python3
"""Patch compiler/rustc/src/main.rs to grow the main thread stack on Redox.

The Redox kernel gives the main thread ~8KB of stack, which isn't enough for
rustc's session setup (~12KB needed before the worker thread is spawned).
The kernel doesn't respect PT_GNU_STACK, so we can't set stack size in ELF.

Fix: on Redox, main() immediately spawns a thread with 16MB stack and runs
rustc_driver::main() there. Since rustc_driver::main() calls process::exit(),
the whole process terminates when the spawned thread finishes.
"""

path = "compiler/rustc/src/main.rs"
with open(path) as f:
    content = f.read()

# Replace the call to rustc_driver::main() with a stack-growing wrapper
old = "    rustc_driver::main()"

new = """    // Redox: the kernel only gives the main thread ~8KB of stack, which is not
    // enough for rustc's session setup before the worker thread is spawned.
    // Spawn a thread with a larger stack and run the compiler there.
    // rustc_driver::main() calls process::exit() internally, so the whole
    // process terminates when the spawned thread finishes.
    #[cfg(target_os = "redox")]
    {
        let stack_size = 16 * 1024 * 1024; // 16 MB
        match std::thread::Builder::new()
            .name("rustc-main".into())
            .stack_size(stack_size)
            .spawn(|| rustc_driver::main())
        {
            Ok(handle) => {
                let _ = handle.join();
                // If we get here, the thread exited without calling process::exit
                std::process::exit(0);
            }
            Err(e) => {
                eprintln!("rustc: failed to create main thread: {e}");
                std::process::exit(1);
            }
        }
    }

    #[cfg(not(target_os = "redox"))]
    rustc_driver::main()"""

if old in content:
    content = content.replace(old, new)
    with open(path, 'w') as f:
        f.write(content)
    print(f"  Patched {path}: Redox stack-growing main thread wrapper")
else:
    print(f"  WARNING: could not find rustc_driver::main() call in {path}")
    import sys
    sys.exit(1)
