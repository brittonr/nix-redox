## 1. Kernel Patch

- [x] 1.1 Create `nix/pkgs/system/patches/patch-kernel-p2frame-init.py` that modifies `src/context/memory.rs`:
  - In `zeroed_phys_contiguous`: after `allocate_p2frame(alloc_order)`, add a loop that sets `RefCount::One` on ALL `1 << alloc_order` frames (not just `span.count`)
  - Add `alloc_order: Option<u32>` field to `Provider::Allocated`
  - Set `alloc_order: Some(alloc_order)` in the `zeroed_phys_contiguous` Grant, `alloc_order: None` in all other `Provider::Allocated` constructors
  - In `handle_free_action`: when `alloc_order` is `Some(order)`, decrement refcounts on all `1 << order` frames then call `deallocate_p2frame(base, order)` once
- [x] 1.2 Update all other `Provider::Allocated { .. }` constructor sites in `context/memory.rs` to include `alloc_order: None`
- [x] 1.3 Update all pattern matches on `Provider::Allocated` to handle the new `alloc_order` field

## 2. Nix Build Integration

- [x] 2.1 Wire the patch into `nix/pkgs/system/kernel.nix` patchPhase (call `python3 patch-kernel-p2frame-init.py` on the source)
- [x] 2.2 Run `nix build .#kernel` and verify the patched kernel compiles cleanly

## 3. Validation

- [x] 3.1 Run `nix run .#boot-test` to confirm the patched kernel boots and passes existing tests
- [x] 3.2 Run `nix run .#bridge-test` to verify virtio-fsd DMA buffers still work (this exercises the phys_contiguous path)

## 4. Documentation

- [x] 4.1 Update `virtio-fsd/src/transport.rs` module-level doc comment to note the kernel fix exists (keep `round_to_p2_pages` as defense in depth)
- [x] 4.2 Update AGENTS.md "Kernel DMA page allocator bug" entry — move from active bug to fixed
- [x] 4.3 Update `.agent/napkin.md` — move bug entry to "Stale Claims (verified fixed)" section
