#!/usr/bin/env python3
"""
Patch relibc's fork_impl() to avoid heap allocation during fork.

Root cause of JOBS>1 hang: fork_impl() calls alloc::format!() to
build "grant-fd-{:>016x}" strings while the allocator lock is held
(via pthread_atfork prepare hook). In multi-threaded processes,
thread stacks are GRANT_SCHEME|GRANT_SHARED grants, so the loop
body executes and tries to allocate → deadlock on the non-reentrant
allocator mutex.

Fix: Use stack-based hex formatting instead of alloc::format!().
This avoids all heap allocation during the critical fork section.

Target file: redox-rt/src/proc.rs (inside relibc source tree)
"""

import sys
import os


def patch_file(path):
    with open(path, "r") as f:
        content = f.read()

    original = content

    # Replace the entire buf declaration + both cfg blocks with a single
    # stack-based implementation that avoids all heap allocation.
    old_block = """                    let buf;

                    // TODO: write! using some #![no_std] Cursor type (tracking the length)?
                    #[cfg(target_pointer_width = "64")]
                    {
                        //buf = *b"grant-fd-AAAABBBBCCCCDDDD";
                        //write!(&mut buf, "grant-fd-{:>016x}", grant.base).unwrap();
                        buf = alloc::format!("grant-fd-{:>016x}", grant.base).into_bytes();
                    }

                    #[cfg(target_pointer_width = "32")]
                    {
                        //buf = *b"grant-fd-AAAABBBB";
                        //write!(&mut buf[..], "grant-fd-{:>08x}", grant.base).unwrap();
                        buf = alloc::format!("grant-fd-{:>08x}", grant.base).into_bytes();
                    }

                    let grant_fd = cur_addr_space_fd.dup(&buf)?.to_upper()?;"""

    new_block = """                    // Stack-based hex formatting to avoid heap allocation during fork.
                    // The allocator lock is held by the atfork prepare hook, and
                    // alloc::format! would deadlock on the non-reentrant allocator mutex.
                    // This is the root cause of the JOBS>1 cargo hang: in multi-threaded
                    // processes, thread stacks are GRANT_SCHEME|GRANT_SHARED grants that
                    // enter this loop body and trigger allocation.
                    let hex_chars: &[u8; 16] = b"0123456789abcdef";
                    #[cfg(target_pointer_width = "64")]
                    let mut buf = *b"grant-fd-0000000000000000";
                    #[cfg(target_pointer_width = "32")]
                    let mut buf = *b"grant-fd-00000000";

                    let val = grant.base;
                    let hex_len = core::mem::size_of::<usize>() * 2;
                    for i in 0..hex_len {
                        buf[9 + i] = hex_chars[(val >> ((hex_len - 1 - i) * 4)) & 0xf];
                    }

                    let grant_fd = cur_addr_space_fd.dup(&buf)?.to_upper()?;"""

    if old_block in content:
        content = content.replace(old_block, new_block)
        print("  Patched: grant-fd format → stack buffer (no heap allocation)")
    else:
        print(f"  WARNING: grant-fd allocation pattern not found in {path}")
        return False

    if content != original:
        with open(path, "w") as f:
            f.write(content)
        return True
    return False


def main():
    if len(sys.argv) < 2:
        print("Usage: patch-relibc-fork-noalloc.py <relibc-source-dir>")
        sys.exit(1)

    src_dir = sys.argv[1]
    target = os.path.join(src_dir, "redox-rt", "src", "proc.rs")

    if not os.path.exists(target):
        print(f"ERROR: {target} not found")
        sys.exit(1)

    print(f"Patching {target}...")
    if patch_file(target):
        print("Done! fork_impl() no longer allocates during fork.")
    else:
        print("WARNING: Patch failed!")
        sys.exit(1)


if __name__ == "__main__":
    main()
