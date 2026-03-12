## Context

The Redox kernel's physical frame allocator uses a buddy system with `PageInfo` tracking per frame. `allocate_p2frame(order)` always allocates exactly 2^order frames. The `zeroed_phys_contiguous` function wraps this to provide mapped, zeroed, physically contiguous memory to userspace drivers (DMA buffers). It accepts a `PageSpan` whose `count` field may not be a power of two.

Currently `zeroed_phys_contiguous` allocates 2^order frames but only sets `RC_USED_NOT_FREE` on `span.count` of them. The excess frames have zeroed PageInfo, which the buddy allocator interprets as "free" during merge checks — corrupting the freelist.

The deallocation path (`handle_free_action`) also has a problem: it frees `span.count` individual frames via `deallocate_frame` (order 0) rather than a single `deallocate_p2frame(base, order)`. The code itself has a `// FIXME use a single deallocate_p2frame when possible` comment.

The only current caller is virtio-fsd, which works around both problems by pre-rounding to power-of-two page counts. The kernel fix makes this workaround unnecessary (though we keep it for defense in depth).

## Goals / Non-Goals

**Goals:**
- All frames returned by `allocate_p2frame` are marked used, regardless of how many the caller maps.
- Deallocation of phys_contiguous grants returns the full 2^order block in one call.
- The fix is a kernel source patch applied via the existing Nix kernel build.
- Existing callers (virtio-fsd) continue to work without changes.

**Non-Goals:**
- Rewriting the buddy allocator itself. The allocator is correct; the bug is in `zeroed_phys_contiguous`'s incomplete initialization.
- Supporting runtime page count changes after allocation (grow/shrink).
- Fixing the separate `TheFrameAllocator` path (it already rounds to power-of-two via `next_power_of_two().trailing_zeros()`).

## Decisions

### 1. Mark all 2^order frames as used during allocation

In `zeroed_phys_contiguous`, after `allocate_p2frame(alloc_order)`, iterate all `1 << alloc_order` frames and set `RefCount::One`. Currently only `span.count` frames get this treatment. The excess frames beyond `span.count` are not mapped into the process address space — they're "dark pages" owned by the allocation but not visible to userspace.

**Alternative**: Only allocate exactly `span.count` frames using the non-contiguous path. Rejected because `phys_contiguous` exists specifically for DMA, which requires physically contiguous memory.

### 2. Store allocation order in Provider::Allocated

Add an `alloc_order: Option<u32>` field to `Provider::Allocated` (only `Some` when `phys_contiguous: true`). This tells the deallocation path how many frames were actually allocated, independent of how many were mapped. The `page_count` field in `GrantInfo` continues to track the mapped count for everything else (virtual memory management, page table cleanup).

**Alternative**: Compute order from `page_count` at deallocation time. Rejected because `page_count` is the requested count (not power-of-two), so we'd be re-deriving information we already knew at allocation time. Storing it is cleaner and avoids any rounding ambiguity.

### 3. Single deallocate_p2frame call on free

`handle_free_action` checks for the new `alloc_order` field. When present, it calls `deallocate_p2frame(base, alloc_order)` once instead of `deallocate_frame` in a loop. This is both correct (the buddy allocator expects to free at the same order it allocated) and faster (one merge pass instead of N).

For the `span.count` mapped pages, their PageInfo refcount must be decremented first. For the excess dark pages, their refcount is already `RC_USED_NOT_FREE | 1` (set during allocation), so we decrement those too. Then a single `deallocate_p2frame(base, order)` frees the whole block.

**Alternative**: Keep per-frame deallocation but also free the dark pages. Rejected because deallocating individual frames triggers O(N) merge attempts, and the FIXME comment already identifies this as the wrong approach.

### 4. Kernel patch via Python script

Following the existing pattern (`patch-relibc-*.py`, `patch-cargo-*.py`), the fix is a Python patch script (`patch-kernel-p2frame-init.py`) that modifies the kernel source during the Nix build. It targets `src/context/memory.rs` specifically.

### 5. Keep virtio-fsd workaround

The `round_to_p2_pages` function in virtio-fsd stays. Defense in depth — the driver shouldn't depend on kernel correctness for safety-critical DMA buffers. The doc comments are updated to note the kernel fix exists.

## Risks / Trade-offs

- **Memory waste for non-p2 allocations**: A 257-page request allocates 512 pages, wasting 255 pages. This is already the case today (the kernel already allocates 2^order pages). The fix just makes the accounting correct — previously those 255 pages were leaked silently.

- **Patch maintenance**: The kernel patch must be updated if upstream `context/memory.rs` changes significantly. Mitigated by targeting a specific git rev (pinned in flake.lock) and keeping the patch minimal.

- **Provider enum size increase**: Adding `alloc_order: Option<u32>` to `Provider::Allocated` increases its size by 8 bytes (4 bytes data + 4 padding). Negligible given one Grant per mapped region.
