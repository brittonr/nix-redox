import sys
import re

file_path = sys.argv[1]
with open(file_path, 'r') as f:
    content = f.read()

# Replace ptr import to remove NonNull
content = content.replace('use std::ptr::{self, NonNull};', 'use std::ptr;')

# Replace GraphicScreen struct - need to handle the new fields
old_struct = """pub struct GraphicScreen {
    width: usize,
    height: usize,
    ptr: NonNull<[u32]>,
}"""

# Store both the aligned pointer and the original allocation pointer for proper deallocation
new_struct = """pub struct GraphicScreen {
    width: usize,
    height: usize,
    // Aligned pointer to framebuffer data (page-aligned for kernel mmap)
    ptr: *mut u32,
    // Original allocation pointer (for deallocation)
    alloc_ptr: *mut u8,
    // Number of pixels
    len: usize,
    // Layout for deallocation
    alloc_layout: Layout,
}"""

if old_struct in content:
    content = content.replace(old_struct, new_struct)
    print("Replaced GraphicScreen struct")
else:
    print("WARNING: Could not find GraphicScreen struct")

# Replace impl GraphicScreen block with new() that does manual alignment
old_impl = """impl GraphicScreen {
    fn new(width: usize, height: usize) -> GraphicScreen {
        let len = width * height;
        let layout = Self::layout(len);
        let ptr = unsafe { alloc::alloc_zeroed(layout) };
        let ptr = ptr::slice_from_raw_parts_mut(ptr.cast(), len);
        let ptr = NonNull::new(ptr).unwrap_or_else(|| alloc::handle_alloc_error(layout));

        GraphicScreen { width, height, ptr }
    }

    #[inline]
    fn layout(len: usize) -> Layout {
        // optimizes to an integer mul
        Layout::array::<u32>(len)
            .unwrap()
            .align_to(PAGE_SIZE)
            .unwrap()
    }
}"""

# New implementation uses over-allocation to guarantee page alignment
new_impl = """impl GraphicScreen {
    fn new(width: usize, height: usize) -> GraphicScreen {
        let len = width * height;
        let byte_size = len * std::mem::size_of::<u32>();

        // Over-allocate by PAGE_SIZE to guarantee we can find a page-aligned address
        // within the allocation. This is necessary because the kernel fmap validation
        // requires page-aligned base addresses.
        let alloc_size = byte_size + PAGE_SIZE;
        let alloc_layout = Layout::from_size_align(alloc_size, std::mem::align_of::<u32>())
            .expect("Failed to create layout");

        let alloc_ptr = unsafe { alloc::alloc_zeroed(alloc_layout) };
        if alloc_ptr.is_null() {
            alloc::handle_alloc_error(alloc_layout);
        }

        // Align the pointer up to the next page boundary
        let alloc_addr = alloc_ptr as usize;
        let aligned_addr = (alloc_addr + PAGE_SIZE - 1) & !(PAGE_SIZE - 1);
        let ptr = aligned_addr as *mut u32;

        eprintln!(
            "GraphicScreen: alloc_addr={:#x}, aligned_addr={:#x}, page_aligned={}",
            alloc_addr, aligned_addr, aligned_addr % PAGE_SIZE == 0
        );

        GraphicScreen { width, height, ptr, alloc_ptr, len, alloc_layout }
    }
}"""

if old_impl in content:
    content = content.replace(old_impl, new_impl)
    print("Replaced impl GraphicScreen block")
else:
    print("WARNING: Could not find impl GraphicScreen block")

# Replace Drop impl
old_drop = """impl Drop for GraphicScreen {
    fn drop(&mut self) {
        let layout = Self::layout(self.ptr.len());
        unsafe { alloc::dealloc(self.ptr.as_ptr().cast(), layout) };
    }
}"""

new_drop = """impl Drop for GraphicScreen {
    fn drop(&mut self) {
        // Deallocate using the original allocation pointer, not the aligned one
        unsafe { alloc::dealloc(self.alloc_ptr, self.alloc_layout) };
    }
}"""

if old_drop in content:
    content = content.replace(old_drop, new_drop)
    print("Replaced Drop impl")
else:
    print("WARNING: Could not find Drop impl")

# Replace all remaining .as_ptr() usages on ptr fields (may appear in different contexts)
# The .as_ptr() method doesn't exist on raw pointers
# Use regex to handle potential whitespace variations

# self.ptr.as_ptr() as *mut u32 -> self.ptr
content = re.sub(r'self\.ptr\.as_ptr\(\)\s*as\s*\*mut\s*u32', 'self.ptr', content)

# framebuffer.ptr.as_ptr().cast::<u8>() -> framebuffer.ptr as *mut u8
# This is in map_dumb_framebuffer where 'framebuffer' is actually a GraphicScreen
content = re.sub(r'framebuffer\.ptr\.as_ptr\(\)\.cast::<u8>\(\)', 'framebuffer.ptr as *mut u8', content)

# Any other .ptr.as_ptr() patterns
content = re.sub(r'\.ptr\.as_ptr\(\)', '.ptr', content)

# Also replace any self.ptr.len() calls since ptr is now raw
content = re.sub(r'self\.ptr\.len\(\)', 'self.len', content)

print("Replaced .as_ptr() and .len() usages on ptr fields")

with open(file_path, 'w') as f:
    f.write(content)

print("Python patching complete")
