## Why

The kernel's `zeroed_phys_contiguous` allocates 2^order pages via `allocate_p2frame(order)` but only initializes `span.count` of them with `RC_USED_NOT_FREE` refcount. When `span.count` is not a power of two (e.g., 257 pages → order 9 → 512 allocated), the excess pages (257–511) retain zeroed PageInfo. The buddy allocator's `deallocate_p2frame` checks sibling pages during merge: zeroed refcount passes the `as_free()` check, so it tries to unlink a page that was never on any freelist — corrupting the freelist via stale prev/next pointers. In debug kernels this panics; in release kernels it silently wipes freelist entries, leaking or double-freeing memory.

The only consumer currently is the virtio-fs driver (DMA buffers), which works around the bug by rounding allocations to power-of-two page counts. The fix belongs in the kernel so all future callers of `zeroed_phys_contiguous` are safe regardless of page count.

## What Changes

- `zeroed_phys_contiguous` initializes ALL 2^order pages' PageInfo with `RC_USED_NOT_FREE`, not just `span.count`.
- The grant tracks the actual allocated page count (2^order) alongside the mapped page count (`span.count`) so deallocation frees all allocated pages.
- `handle_free_action` frees the full 2^order allocation with a single `deallocate_p2frame(base, order)` instead of individual per-frame `deallocate_frame` calls (also resolves the existing `FIXME` comment in the code).
- A kernel patch is added to the Nix build for the Redox kernel.
- The `round_to_p2_pages` workaround in `virtio-fsd` is kept (defense in depth) but its documentation is updated to note the kernel fix.

## Capabilities

### New Capabilities
- `p2frame-init-fix`: Correct PageInfo initialization for non-power-of-two phys_contiguous allocations, and proper bulk deallocation via `deallocate_p2frame`.

### Modified Capabilities

## Impact

- **Kernel**: `src/context/memory.rs` — `zeroed_phys_contiguous`, `handle_free_action`, `GrantInfo`/`Provider` (to carry allocation order).
- **Nix build**: `nix/pkgs/system/kernel.nix` — new patch file applied during kernel build.
- **virtio-fsd**: Documentation-only update in `transport.rs` (workaround stays, adds note about upstream fix).
- **AGENTS.md / napkin**: Bug entry updated from "active" to "fixed".
