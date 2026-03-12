#!/usr/bin/env python3
"""
Patch kernel zeroed_phys_contiguous to initialize ALL 2^order pages.

Bug: zeroed_phys_contiguous allocates 2^order pages via allocate_p2frame(order)
but only sets RefCount::One on span.count of them. Excess pages retain zeroed
PageInfo, which the buddy allocator interprets as "free" during merge checks —
corrupting the freelist.

Fix:
1. After allocate_p2frame, set RefCount::One on ALL 1 << alloc_order frames.
2. Add alloc_order: Option<u32> to Provider::Allocated so deallocation knows
   how many frames were actually allocated.
3. In handle_free_action, use a single deallocate_p2frame(base, order) call
   instead of per-frame deallocate_frame (resolves existing FIXME).

Target file: src/context/memory.rs (inside kernel source tree)
"""

import sys
import os


def patch_file(path):
    with open(path, "r") as f:
        content = f.read()

    original = content
    patched_any = False

    # --- Patch 1: Add alloc_order field to Provider::Allocated ---
    old_provider = """    Allocated {
        cow_file_ref: Option<GrantFileRef>,
        phys_contiguous: bool,
    },"""

    new_provider = """    Allocated {
        cow_file_ref: Option<GrantFileRef>,
        phys_contiguous: bool,
        /// When phys_contiguous is true, stores the allocation order so
        /// deallocation can free all 2^order frames in one call.
        alloc_order: Option<u32>,
    },"""

    if old_provider in content:
        content = content.replace(old_provider, new_provider)
        print("  Patched: Provider::Allocated — added alloc_order field")
        patched_any = True
    else:
        print("  WARNING: Provider::Allocated definition not found")
        return False

    # --- Patch 2: zeroed_phys_contiguous — init ALL 2^order frames ---
    old_zeroed_phys = """        let alloc_order = span.count.next_power_of_two().trailing_zeros();
        let base = crate::memory::allocate_p2frame(alloc_order).ok_or(Enomem)?;

        for (i, page) in span.pages().enumerate() {
            let frame = base.next_by(i);

            get_page_info(frame)
                .expect("PageInfo must exist for allocated frame")
                .refcount
                .store(RefCount::One.to_raw(), Ordering::Relaxed);

            unsafe {
                let result = mapper
                    .map_phys(page.start_address(), frame.base(), flags)
                    .expect("TODO: page table OOM");
                result.ignore();

                flusher.queue(frame, None, TlbShootdownActions::NEW_MAPPING);
            }
        }

        Ok(Grant {
            base: span.base,
            info: GrantInfo {
                page_count: span.count,
                flags,
                mapped: true,
                provider: Provider::Allocated {
                    cow_file_ref: None,
                    phys_contiguous: true,
                },
            },
        })"""

    new_zeroed_phys = """        let alloc_order = span.count.next_power_of_two().trailing_zeros();
        let base = crate::memory::allocate_p2frame(alloc_order).ok_or(Enomem)?;

        // Initialize ALL 2^order frames with RefCount::One, not just span.count.
        // Excess frames beyond span.count are "dark pages" — owned by the allocation
        // but not mapped into userspace. Without this, the buddy allocator sees their
        // zeroed PageInfo as "free" and corrupts the freelist during merge.
        let total_frames = 1usize << alloc_order;
        for i in 0..total_frames {
            let frame = base.next_by(i);
            get_page_info(frame)
                .expect("PageInfo must exist for allocated frame")
                .refcount
                .store(RefCount::One.to_raw(), Ordering::Relaxed);
        }

        // Map only the requested span.count pages into the process address space.
        for (i, page) in span.pages().enumerate() {
            let frame = base.next_by(i);

            unsafe {
                let result = mapper
                    .map_phys(page.start_address(), frame.base(), flags)
                    .expect("TODO: page table OOM");
                result.ignore();

                flusher.queue(frame, None, TlbShootdownActions::NEW_MAPPING);
            }
        }

        Ok(Grant {
            base: span.base,
            info: GrantInfo {
                page_count: span.count,
                flags,
                mapped: true,
                provider: Provider::Allocated {
                    cow_file_ref: None,
                    phys_contiguous: true,
                    alloc_order: Some(alloc_order),
                },
            },
        })"""

    if old_zeroed_phys in content:
        content = content.replace(old_zeroed_phys, new_zeroed_phys)
        print("  Patched: zeroed_phys_contiguous — init all 2^order frames + store alloc_order")
        patched_any = True
    else:
        print("  WARNING: zeroed_phys_contiguous body not found")
        return False

    # --- Patch 3: handle_free_action — bulk deallocation via deallocate_p2frame ---
    old_handle_free = """fn handle_free_action(base: Frame, phys_contiguous_count: Option<NonZeroUsize>) {
    if let Some(count) = phys_contiguous_count {
        for i in 0..count.get() {
            let frame = base.next_by(i);
            let new_rc = get_page_info(frame)
                .expect("phys_contiguous frames all need PageInfos")
                .remove_ref();

            if new_rc.is_none() {
                // FIXME use a single deallocate_p2frame when possible
                unsafe {
                    deallocate_frame(frame);
                }
            }
        }
    } else {"""

    new_handle_free = """fn handle_free_action(base: Frame, phys_contiguous_count: Option<NonZeroUsize>, alloc_order: Option<u32>) {
    if let Some(order) = alloc_order {
        // Bulk deallocation: decrement refcounts on all 2^order frames (both
        // mapped and dark pages), then free the entire block in one call.
        // We discard remove_ref()'s return value because deallocate_p2frame
        // handles the actual freeing for the whole block at once.
        let total_frames = 1usize << order;
        for i in 0..total_frames {
            let frame = base.next_by(i);
            let _ = get_page_info(frame)
                .expect("phys_contiguous frames all need PageInfos")
                .remove_ref();
        }
        unsafe {
            crate::memory::deallocate_p2frame(base, order);
        }
    } else if let Some(count) = phys_contiguous_count {
        for i in 0..count.get() {
            let frame = base.next_by(i);
            let new_rc = get_page_info(frame)
                .expect("phys_contiguous frames all need PageInfos")
                .remove_ref();

            if new_rc.is_none() {
                unsafe {
                    deallocate_frame(frame);
                }
            }
        }
    } else {"""

    if old_handle_free in content:
        content = content.replace(old_handle_free, new_handle_free)
        print("  Patched: handle_free_action — bulk deallocate_p2frame for alloc_order")
        patched_any = True
    else:
        print("  WARNING: handle_free_action body not found")
        return False

    # --- Patch 4: Update all call sites of handle_free_action to pass alloc_order ---
    # NopFlusher::queue calls handle_free_action
    old_nop_flusher_call = """impl GenericFlusher for NopFlusher {
    fn queue(
        &mut self,
        frame: Frame,
        phys_contiguous_count: Option<NonZeroUsize>,
        actions: TlbShootdownActions,
    ) {
        if actions.contains(TlbShootdownActions::FREE) {
            handle_free_action(frame, phys_contiguous_count);
        }
    }
}"""

    new_nop_flusher_call = """impl GenericFlusher for NopFlusher {
    fn queue(
        &mut self,
        frame: Frame,
        phys_contiguous_count: Option<NonZeroUsize>,
        actions: TlbShootdownActions,
    ) {
        if actions.contains(TlbShootdownActions::FREE) {
            handle_free_action(frame, phys_contiguous_count, None);
        }
    }
}"""

    if old_nop_flusher_call in content:
        content = content.replace(old_nop_flusher_call, new_nop_flusher_call)
        print("  Patched: NopFlusher::queue — pass None for alloc_order")
        patched_any = True
    else:
        print("  WARNING: NopFlusher::queue call site not found")
        return False

    # Flusher::flush calls handle_free_action in the page queue drain loop
    old_flusher_flush_call = """            handle_free_action(base, phys_contiguous_count);"""
    new_flusher_flush_call = """            handle_free_action(base, phys_contiguous_count, None);"""

    if old_flusher_flush_call in content:
        content = content.replace(old_flusher_flush_call, new_flusher_flush_call)
        print("  Patched: Flusher::flush — pass None for alloc_order")
        patched_any = True
    else:
        print("  WARNING: Flusher::flush handle_free_action call not found")
        return False

    # --- Patch 5: unmap() — pass alloc_order through the flusher for phys_contiguous ---
    # The unmap method extracts phys_contiguous base and calls flusher.queue.
    # We need to also extract alloc_order and thread it through.

    # First, update the GenericFlusher trait to carry alloc_order
    old_trait = """pub trait GenericFlusher {
    // TODO: Don't require a frame unless FREE, require Page otherwise
    fn queue(
        &mut self,
        frame: Frame,
        phys_contiguous_count: Option<NonZeroUsize>,
        actions: TlbShootdownActions,
    );
}"""

    new_trait = """pub trait GenericFlusher {
    // TODO: Don't require a frame unless FREE, require Page otherwise
    fn queue(
        &mut self,
        frame: Frame,
        phys_contiguous_count: Option<NonZeroUsize>,
        actions: TlbShootdownActions,
    );
    fn queue_with_order(
        &mut self,
        frame: Frame,
        phys_contiguous_count: Option<NonZeroUsize>,
        alloc_order: Option<u32>,
        actions: TlbShootdownActions,
    ) {
        // Default: ignore alloc_order, fall back to queue()
        let _ = alloc_order;
        self.queue(frame, phys_contiguous_count, actions);
    }
}"""

    if old_trait in content:
        content = content.replace(old_trait, new_trait)
        print("  Patched: GenericFlusher trait — added queue_with_order default method")
        patched_any = True
    else:
        print("  WARNING: GenericFlusher trait not found")
        return False

    # Update NopFlusher to override queue_with_order
    old_nop_impl_end = """impl GenericFlusher for NopFlusher {
    fn queue(
        &mut self,
        frame: Frame,
        phys_contiguous_count: Option<NonZeroUsize>,
        actions: TlbShootdownActions,
    ) {
        if actions.contains(TlbShootdownActions::FREE) {
            handle_free_action(frame, phys_contiguous_count, None);
        }
    }
}"""

    new_nop_impl_end = """impl GenericFlusher for NopFlusher {
    fn queue(
        &mut self,
        frame: Frame,
        phys_contiguous_count: Option<NonZeroUsize>,
        actions: TlbShootdownActions,
    ) {
        if actions.contains(TlbShootdownActions::FREE) {
            handle_free_action(frame, phys_contiguous_count, None);
        }
    }
    fn queue_with_order(
        &mut self,
        frame: Frame,
        phys_contiguous_count: Option<NonZeroUsize>,
        alloc_order: Option<u32>,
        actions: TlbShootdownActions,
    ) {
        if actions.contains(TlbShootdownActions::FREE) {
            handle_free_action(frame, phys_contiguous_count, alloc_order);
        }
    }
}"""

    if old_nop_impl_end in content:
        content = content.replace(old_nop_impl_end, new_nop_impl_end)
        print("  Patched: NopFlusher — added queue_with_order override")
        patched_any = True
    else:
        print("  WARNING: NopFlusher impl (updated) not found")
        return False

    # Update PageQueueEntry to carry alloc_order
    old_pqe = """enum PageQueueEntry {
    Free {
        base: Frame,
        phys_contiguous_count: Option<NonZeroUsize>,
    },"""

    new_pqe = """enum PageQueueEntry {
    Free {
        base: Frame,
        phys_contiguous_count: Option<NonZeroUsize>,
        alloc_order: Option<u32>,
    },"""

    if old_pqe in content:
        content = content.replace(old_pqe, new_pqe)
        print("  Patched: PageQueueEntry::Free — added alloc_order field")
        patched_any = True
    else:
        print("  WARNING: PageQueueEntry::Free not found")
        return False

    # Update Flusher::flush to destructure and pass alloc_order
    old_flush_destructure = """            let PageQueueEntry::Free {
                base,
                phys_contiguous_count,
            } = entry
            else {
                continue;
            };
            handle_free_action(base, phys_contiguous_count, None);"""

    new_flush_destructure = """            let PageQueueEntry::Free {
                base,
                phys_contiguous_count,
                alloc_order,
            } = entry
            else {
                continue;
            };
            handle_free_action(base, phys_contiguous_count, alloc_order);"""

    if old_flush_destructure in content:
        content = content.replace(old_flush_destructure, new_flush_destructure)
        print("  Patched: Flusher::flush — destructure and pass alloc_order")
        patched_any = True
    else:
        print("  WARNING: Flusher::flush destructure not found")
        return False

    # Update Flusher GenericFlusher impl — queue() constructs PageQueueEntry
    old_flusher_queue = """impl GenericFlusher for Flusher<'_, '_> {
    fn queue(
        &mut self,
        frame: Frame,
        phys_contiguous_count: Option<NonZeroUsize>,
        actions: TlbShootdownActions,
    ) {
        let actions = actions & !TlbShootdownActions::NEW_MAPPING;

        let entry = if actions.contains(TlbShootdownActions::FREE) {
            PageQueueEntry::Free {
                base: frame,
                phys_contiguous_count,
            }
        } else {
            PageQueueEntry::Other { actions }
        };
        self.state.dirty = true;

        if self.state.pagequeue.is_full() {
            self.flush();
        }
        self.state.pagequeue.push(entry);
    }
}"""

    new_flusher_queue = """impl GenericFlusher for Flusher<'_, '_> {
    fn queue(
        &mut self,
        frame: Frame,
        phys_contiguous_count: Option<NonZeroUsize>,
        actions: TlbShootdownActions,
    ) {
        self.queue_with_order(frame, phys_contiguous_count, None, actions);
    }
    fn queue_with_order(
        &mut self,
        frame: Frame,
        phys_contiguous_count: Option<NonZeroUsize>,
        alloc_order: Option<u32>,
        actions: TlbShootdownActions,
    ) {
        let actions = actions & !TlbShootdownActions::NEW_MAPPING;

        let entry = if actions.contains(TlbShootdownActions::FREE) {
            PageQueueEntry::Free {
                base: frame,
                phys_contiguous_count,
                alloc_order,
            }
        } else {
            PageQueueEntry::Other { actions }
        };
        self.state.dirty = true;

        if self.state.pagequeue.is_full() {
            self.flush();
        }
        self.state.pagequeue.push(entry);
    }
}"""

    if old_flusher_queue in content:
        content = content.replace(old_flusher_queue, new_flusher_queue)
        print("  Patched: Flusher GenericFlusher impl — queue delegates to queue_with_order")
        patched_any = True
    else:
        print("  WARNING: Flusher GenericFlusher impl not found")
        return False

    # --- Patch 6: unmap() — extract alloc_order and use queue_with_order ---
    old_unmap_phys_contig = """        if is_phys_contiguous {
            let (phys_base, _) = mapper.translate(self.base.start_address()).unwrap();
            let base_frame = Frame::containing(phys_base);

            for i in 0..self.info.page_count {
                unsafe {
                    let (phys, _, flush) = mapper
                        .unmap_phys(self.base.next_by(i).start_address(), true)
                        .expect("all physborrowed grants must be fully Present in the page tables");
                    flush.ignore();

                    assert_eq!(phys, base_frame.next_by(i).base());
                }
            }

            flusher.queue(
                base_frame,
                Some(NonZeroUsize::new(self.info.page_count).unwrap()),
                TlbShootdownActions::FREE,
            );"""

    new_unmap_phys_contig = """        let phys_contig_alloc_order = match self.info.provider {
            Provider::Allocated { alloc_order, phys_contiguous: true, .. } => alloc_order,
            _ => None,
        };

        if is_phys_contiguous {
            let (phys_base, _) = mapper.translate(self.base.start_address()).unwrap();
            let base_frame = Frame::containing(phys_base);

            for i in 0..self.info.page_count {
                unsafe {
                    let (phys, _, flush) = mapper
                        .unmap_phys(self.base.next_by(i).start_address(), true)
                        .expect("all physborrowed grants must be fully Present in the page tables");
                    flush.ignore();

                    assert_eq!(phys, base_frame.next_by(i).base());
                }
            }

            flusher.queue_with_order(
                base_frame,
                Some(NonZeroUsize::new(self.info.page_count).unwrap()),
                phys_contig_alloc_order,
                TlbShootdownActions::FREE,
            );"""

    if old_unmap_phys_contig in content:
        content = content.replace(old_unmap_phys_contig, new_unmap_phys_contig)
        print("  Patched: unmap() — extract alloc_order, use queue_with_order for phys_contiguous")
        patched_any = True
    else:
        print("  WARNING: unmap() phys_contiguous block not found")
        return False

    # --- Patch 7: Add alloc_order: None to all other Provider::Allocated constructors ---

    # allocated_one_page_nomap
    old_alloc_one = """                provider: Provider::Allocated {
                    cow_file_ref: None,
                    phys_contiguous: false,
                },
            },
        }
    }

    // TODO: is_pinned
    pub fn allocated_shared_one_page("""

    new_alloc_one = """                provider: Provider::Allocated {
                    cow_file_ref: None,
                    phys_contiguous: false,
                    alloc_order: None,
                },
            },
        }
    }

    // TODO: is_pinned
    pub fn allocated_shared_one_page("""

    if old_alloc_one in content:
        content = content.replace(old_alloc_one, new_alloc_one)
        print("  Patched: allocated_one_page_nomap — added alloc_order: None")
        patched_any = True
    else:
        print("  WARNING: allocated_one_page_nomap Provider::Allocated not found")
        return False

    # zeroed() — non-shared path
    old_zeroed_provider = """                } else {
                    Provider::Allocated {
                        cow_file_ref: None,
                        phys_contiguous: false,
                    }
                },
            },
        })
    }

    // XXX: borrow_grant"""

    new_zeroed_provider = """                } else {
                    Provider::Allocated {
                        cow_file_ref: None,
                        phys_contiguous: false,
                        alloc_order: None,
                    }
                },
            },
        })
    }

    // XXX: borrow_grant"""

    if old_zeroed_provider in content:
        content = content.replace(old_zeroed_provider, new_zeroed_provider)
        print("  Patched: zeroed() — added alloc_order: None")
        patched_any = True
    else:
        print("  WARNING: zeroed() Provider::Allocated not found")
        return False

    # copy_mappings — Owned path
    old_copy_owned = """                    CopyMappingsMode::Owned { cow_file_ref } => Provider::Allocated {
                        cow_file_ref,
                        phys_contiguous: false,
                    },"""

    new_copy_owned = """                    CopyMappingsMode::Owned { cow_file_ref } => Provider::Allocated {
                        cow_file_ref,
                        phys_contiguous: false,
                        alloc_order: None,
                    },"""

    if old_copy_owned in content:
        content = content.replace(old_copy_owned, new_copy_owned)
        print("  Patched: copy_mappings Owned — added alloc_order: None")
        patched_any = True
    else:
        print("  WARNING: copy_mappings Owned Provider::Allocated not found")
        return False

    # --- Patch 8: Update pattern matches on Provider::Allocated ---

    # try_clone: phys_contiguous: true match
    old_clone_phys = """                Provider::Allocated {
                    phys_contiguous: true,
                    ..
                } => continue,"""

    new_clone_phys = """                Provider::Allocated {
                    phys_contiguous: true,
                    ..
                } => continue,  // alloc_order covered by .."""

    if old_clone_phys in content:
        content = content.replace(old_clone_phys, new_clone_phys)
        print("  Patched: try_clone phys_contiguous match — .. covers alloc_order")
        patched_any = True

    # try_clone: phys_contiguous: false match
    old_clone_nonphys = """                Provider::Allocated {
                    ref cow_file_ref,
                    phys_contiguous: false,
                } => Grant::copy_mappings("""

    new_clone_nonphys = """                Provider::Allocated {
                    ref cow_file_ref,
                    phys_contiguous: false,
                    ..
                } => Grant::copy_mappings("""

    if old_clone_nonphys in content:
        content = content.replace(old_clone_nonphys, new_clone_nonphys)
        print("  Patched: try_clone non-phys match — added ..")
        patched_any = True

    # extract() — before_grant Provider::Allocated match
    old_extract_before = """                    Provider::Allocated {
                        ref cow_file_ref, ..
                    } => Provider::Allocated {
                        cow_file_ref: cow_file_ref.clone(),
                        phys_contiguous: false,
                    },"""

    new_extract_before = """                    Provider::Allocated {
                        ref cow_file_ref, ..
                    } => Provider::Allocated {
                        cow_file_ref: cow_file_ref.clone(),
                        phys_contiguous: false,
                        alloc_order: None,
                    },"""

    if old_extract_before in content:
        content = content.replace(old_extract_before, new_extract_before)
        print("  Patched: extract() before_grant — added alloc_order: None")
        patched_any = True

    # extract() — after_grant Provider::Allocated cow_file_ref: None
    old_extract_after_none = """                    Provider::Allocated {
                        cow_file_ref: None, ..
                    } => Provider::Allocated {
                        cow_file_ref: None,
                        phys_contiguous: false,
                    },"""

    new_extract_after_none = """                    Provider::Allocated {
                        cow_file_ref: None, ..
                    } => Provider::Allocated {
                        cow_file_ref: None,
                        phys_contiguous: false,
                        alloc_order: None,
                    },"""

    if old_extract_after_none in content:
        content = content.replace(old_extract_after_none, new_extract_after_none)
        print("  Patched: extract() after_grant cow_file_ref: None — added alloc_order: None")
        patched_any = True

    # extract() — after_grant Provider::Allocated cow_file_ref: Some
    old_extract_after_some = """                    Provider::Allocated {
                        cow_file_ref: Some(ref file_ref),
                        ..
                    } => Provider::Allocated {
                        cow_file_ref: Some(GrantFileRef {
                            base_offset: file_ref.base_offset + this_span.count * PAGE_SIZE,
                            description: Arc::clone(&file_ref.description),
                        }),
                        phys_contiguous: false,
                    },"""

    new_extract_after_some = """                    Provider::Allocated {
                        cow_file_ref: Some(ref file_ref),
                        ..
                    } => Provider::Allocated {
                        cow_file_ref: Some(GrantFileRef {
                            base_offset: file_ref.base_offset + this_span.count * PAGE_SIZE,
                            description: Arc::clone(&file_ref.description),
                        }),
                        phys_contiguous: false,
                        alloc_order: None,
                    },"""

    if old_extract_after_some in content:
        content = content.replace(old_extract_after_some, new_extract_after_some)
        print("  Patched: extract() after_grant cow_file_ref: Some — added alloc_order: None")
        patched_any = True

    # can_be_merged_if_adjacent — two matches
    old_merge_match = """            (
                Provider::Allocated {
                    cow_file_ref: None,
                    phys_contiguous: false,
                },
                Provider::Allocated {
                    cow_file_ref: None,
                    phys_contiguous: false,
                },
            ) => true,"""

    new_merge_match = """            (
                Provider::Allocated {
                    cow_file_ref: None,
                    phys_contiguous: false,
                    alloc_order: None,
                },
                Provider::Allocated {
                    cow_file_ref: None,
                    phys_contiguous: false,
                    alloc_order: None,
                },
            ) => true,"""

    if old_merge_match in content:
        content = content.replace(old_merge_match, new_merge_match)
        print("  Patched: can_be_merged_if_adjacent — added alloc_order: None")
        patched_any = True

    # grant_flags — Provider::Allocated match
    old_grantflags = """            Provider::Allocated {
                ref cow_file_ref,
                phys_contiguous,
            } => {"""

    new_grantflags = """            Provider::Allocated {
                ref cow_file_ref,
                phys_contiguous,
                ..
            } => {"""

    if old_grantflags in content:
        content = content.replace(old_grantflags, new_grantflags)
        print("  Patched: grant_flags — added .. to cover alloc_order")
        patched_any = True

    # unmap() — is_phys_contiguous match
    old_is_phys = """        let is_phys_contiguous = matches!(
            self.info.provider,
            Provider::Allocated {
                phys_contiguous: true,
                ..
            }
        );"""

    # This already uses .., so alloc_order is covered. No change needed.
    if old_is_phys in content:
        print("  OK: is_phys_contiguous match already uses ..")

    # unmap() — Provider::Allocated in is_fmap_shared match
    old_fmap_shared = """        let is_fmap_shared = match self.info.provider {
            Provider::Allocated { .. } => Some(false),"""

    # Already uses .., no change needed.
    if old_fmap_shared in content:
        print("  OK: is_fmap_shared match already uses ..")

    # unmap() — Provider::Allocated in UnmapResult
    old_unmap_cow = """            Provider::Allocated { cow_file_ref, .. } => cow_file_ref,"""

    # Already uses .., no change needed.
    if old_unmap_cow in content:
        print("  OK: UnmapResult cow_file_ref match already uses ..")

    if content != original:
        with open(path, "w") as f:
            f.write(content)
        return True
    return False


def main():
    if len(sys.argv) < 2:
        print("Usage: patch-kernel-p2frame-init.py <kernel-source-dir>")
        sys.exit(1)

    src_dir = sys.argv[1]
    target = os.path.join(src_dir, "src", "context", "memory.rs")

    if not os.path.exists(target):
        print(f"ERROR: {target} not found")
        sys.exit(1)

    print(f"Patching {target}...")
    if patch_file(target):
        print("Done! zeroed_phys_contiguous now initializes all 2^order frames.")
    else:
        print("ERROR: Patch failed!")
        sys.exit(1)


if __name__ == "__main__":
    main()
