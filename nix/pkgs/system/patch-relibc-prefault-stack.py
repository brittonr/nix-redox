#!/usr/bin/env python3
"""Patch relibc's pthread_create to pre-fault the mmap'd thread stack.

The Redox kernel doesn't fully support demand paging for anonymous mmap regions.
When a thread's stack is allocated via mmap, only a few pages are committed.
As the stack grows, page faults on uncommitted pages cause a kernel trap instead
of allocating new physical pages. This limits thread stacks to ~12KB.

Fix: after mmap'ing the stack, write to every page to force physical allocation
before passing the stack to clone().
"""

path = "src/pthread/mod.rs"
with open(path) as f:
    content = f.read()

# Find the line that sets up the TCB after mmap'ing the stack.
# We need to pre-fault between the mmap and the clone.
# The code has:
#   new_tcb.pthread.stack_base = stack_base;
#   new_tcb.pthread.stack_size = stack_size;
# We insert pre-faulting right after stack_base is set.

old = """    new_tcb.pthread.stack_base = stack_base;
    new_tcb.pthread.stack_size = stack_size;"""

new = """    new_tcb.pthread.stack_base = stack_base;
    new_tcb.pthread.stack_size = stack_size;

    // Pre-fault all stack pages: the Redox kernel may not demand-page
    // anonymous mmap regions properly, causing crashes when the stack
    // grows beyond the initially committed pages.
    unsafe {
        let page_size = 4096usize;
        let mut offset = 0;
        while offset < stack_size {
            core::ptr::write_volatile((stack_base as *mut u8).add(offset), 0);
            offset += page_size;
        }
    }"""

if old in content:
    content = content.replace(old, new)
    with open(path, 'w') as f:
        f.write(content)
    print(f"  Patched {path}: pre-fault thread stack pages after mmap")
else:
    print(f"  WARNING: could not find stack_base/stack_size assignment in {path}")
    import sys
    sys.exit(1)
