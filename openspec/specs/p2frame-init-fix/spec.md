## ADDED Requirements

### Requirement: All p2frame pages marked used on phys_contiguous allocation
When `zeroed_phys_contiguous` allocates 2^order pages via `allocate_p2frame(order)`, all 2^order pages SHALL have their PageInfo refcount set to `RC_USED_NOT_FREE | 1` (RefCount::One), not just the `span.count` pages that are mapped into the process address space.

#### Scenario: Non-power-of-two page count allocation
- **WHEN** `zeroed_phys_contiguous` is called with `span.count = 257`
- **THEN** `allocate_p2frame(9)` allocates 512 pages, and all 512 pages have PageInfo refcount set to `RC_USED_NOT_FREE | 1`

#### Scenario: Power-of-two page count allocation
- **WHEN** `zeroed_phys_contiguous` is called with `span.count = 256`
- **THEN** `allocate_p2frame(8)` allocates 256 pages, and all 256 pages have PageInfo refcount set to `RC_USED_NOT_FREE | 1`

#### Scenario: Buddy allocator sibling check after allocation
- **WHEN** a page adjacent to the excess (unmapped) pages of a phys_contiguous allocation is freed by an unrelated deallocation
- **THEN** the buddy allocator's `as_free()` check on the excess page returns `None` (because `RC_USED_NOT_FREE` is set), preventing erroneous merge attempts

### Requirement: Allocation order stored in grant metadata
The `Provider::Allocated` variant SHALL store the allocation order (`alloc_order: Option<u32>`) when `phys_contiguous` is true. This field records the actual number of pages allocated (2^order), which may exceed the mapped page count.

#### Scenario: Grant created for phys_contiguous allocation
- **WHEN** `zeroed_phys_contiguous` allocates with `alloc_order = 9` for a 257-page request
- **THEN** the resulting Grant's Provider has `alloc_order: Some(9)` and `page_count: 257`

#### Scenario: Grant created for non-contiguous allocation
- **WHEN** a non-contiguous allocation creates a Grant
- **THEN** the Grant's Provider has `alloc_order: None`

### Requirement: Bulk deallocation of phys_contiguous grants
When a phys_contiguous grant is freed, the deallocation path SHALL free all 2^order pages as a single `deallocate_p2frame(base, order)` call after decrementing refcounts on all frames.

#### Scenario: Free 257-page phys_contiguous grant
- **WHEN** a grant with `page_count = 257`, `alloc_order = Some(9)` is freed
- **THEN** refcounts are decremented on all 512 frames (257 mapped + 255 excess), and `deallocate_p2frame(base, 9)` is called once

#### Scenario: Free non-contiguous grant unchanged
- **WHEN** a grant with `alloc_order: None` is freed
- **THEN** deallocation follows the existing per-frame path (behavior unchanged)

### Requirement: Kernel patch applied via Nix build
The fix SHALL be implemented as a Python patch script applied during the Nix kernel build phase, following the existing `patch-*.py` convention.

#### Scenario: Kernel builds with patch
- **WHEN** `nix build .#kernel` is run
- **THEN** the build applies `patch-kernel-p2frame-init.py` to `src/context/memory.rs` and the kernel compiles without errors

### Requirement: virtio-fsd workaround retained
The `round_to_p2_pages` workaround in `virtio-fsd/src/transport.rs` SHALL remain as defense in depth. Its documentation SHALL note the kernel fix.

#### Scenario: virtio-fsd DMA allocation with kernel fix present
- **WHEN** virtio-fsd allocates DMA buffers
- **THEN** `round_to_p2_pages` still rounds to power-of-two pages, and documentation references the kernel fix
