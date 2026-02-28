//! FUSE-over-virtqueue transport layer.
//!
//! Sends FUSE requests via the virtio request queue and receives FUSE responses.
//! The virtio-fs device has two queue types:
//!   - Queue 0: hiprio (for FUSE_FORGET, FUSE_BATCH_FORGET — no response expected)
//!   - Queues 1..N: request queues (normal FUSE request/response pairs)
//!
//! Each request is a chain of descriptors:
//!   [request header + args] → [response header + data (WRITE_ONLY)]
//!
//! ## Response buffer sizing
//!
//! virtiofsd uses the response descriptor size to decide how many bytes to
//! `preadv2()` from the host file for FUSE_READ. We use `Buffer::new_sized`
//! to set exact descriptor sizes even though the underlying DMA buffer may
//! be larger. This avoids over-reading while reusing pre-allocated memory.
//!
//! ## DMA buffer strategy
//!
//! Two DMA buffers are pre-allocated once during FUSE session init and reused
//! for every request. Buffer sizes are rounded up to a power-of-two number
//! of pages to work around a Redox kernel buddy allocator bug.
//!
//! ### Kernel bug: non-power-of-two phys_contiguous deallocation
//!
//! The kernel's `zeroed_phys_contiguous` allocates 2^order pages via
//! `allocate_p2frame(order)` but only initializes `span.count` pages with
//! `RC_USED_NOT_FREE` refcount. When `span.count` is not a power of two
//! (e.g., 257 pages → 512 allocated), the excess pages (257–511) retain
//! zeroed PageInfo — making `as_free()` return `Some` even though they
//! aren't on any freelist. On munmap, `handle_free_action` frees only the
//! mapped pages one-by-one. When the last mapped page (e.g., frame 256)
//! is freed, the buddy allocator checks its sibling (frame 257), sees it
//! as "free" (zeroed refcount), and attempts to merge — following stale
//! prev/next pointers that corrupt the freelist. In debug kernels this
//! panics at `debug_assert_eq!(freelist.for_orders[..], Some(sibling))`;
//! in release kernels it silently wipes freelist entries.
//!
//! By ensuring our allocations are power-of-two pages, `span.count` equals
//! `2^order` and ALL allocated pages are properly initialized. The buffers
//! can then be safely dropped without ManuallyDrop.

use common::dma::Dma;
use virtio_core::spec::{Buffer, ChainBuilder, DescriptorFlags};
use virtio_core::transport::Queue;

use crate::fuse::{FuseInHeader, FuseOutHeader};

/// Response buffer size for metadata operations (LOOKUP, GETATTR, OPEN, etc.).
pub const META_RESPONSE: usize = 4096;

/// Page size (4 KiB on x86_64). Must match the kernel's PAGE_SIZE.
const PAGE_SIZE: usize = 4096;

/// Maximum I/O payload for pre-allocated DMA buffers (1 MiB).
///
/// Covers the common case where virtiofsd negotiates max_readahead and
/// max_write ≤ 1 MiB. Operations with payloads exceeding this are rejected.
pub const MAX_IO_SIZE: usize = 1024 * 1024;

/// Round a byte size up to a power-of-two number of pages.
///
/// This is critical for DMA allocations on Redox: the kernel's
/// `zeroed_phys_contiguous` allocates 2^order pages but only initializes
/// `ceil(size / PAGE_SIZE)` of them. If that count isn't a power of two,
/// excess pages have uninitialized PageInfo that corrupts the buddy
/// allocator on deallocation. Rounding up ensures all allocated pages
/// are properly initialized.
fn round_to_p2_pages(size: usize) -> usize {
    let pages = (size + PAGE_SIZE - 1) / PAGE_SIZE;
    pages.next_power_of_two() * PAGE_SIZE
}

/// Allocate a DMA buffer with power-of-two page alignment.
///
/// The buffer is sized to the next power-of-two page count above `size`,
/// ensuring safe deallocation (see module-level docs on the kernel bug).
/// The actual usable capacity may be larger than `size`.
pub fn alloc_dma_buffer(size: usize) -> Result<Dma<[u8]>, FuseTransportError> {
    let aligned_size = round_to_p2_pages(size);
    let buf = unsafe {
        Dma::<[u8]>::zeroed_slice(aligned_size)
            .map_err(|_| FuseTransportError::DmaAlloc)?
            .assume_init()
    };
    Ok(buf)
}

/// Send a FUSE request using pre-allocated DMA buffers.
///
/// The request data must already be copied into `req_buf[..req_len]`.
/// `resp_len` controls the response descriptor size seen by virtiofsd —
/// critical for FUSE_READ where virtiofsd reads exactly descriptor-size
/// bytes from the host file.
///
/// Both buffers must be large enough: `req_buf.len() >= req_len` and
/// `resp_buf.len() >= resp_len`. No DMA allocation or deallocation occurs.
pub fn fuse_exchange(
    queue: &Queue<'_>,
    req_buf: &Dma<[u8]>,
    req_len: usize,
    resp_buf: &Dma<[u8]>,
    resp_len: usize,
) -> Result<Vec<u8>, FuseTransportError> {
    debug_assert!(req_len <= req_buf.len());
    debug_assert!(resp_len <= resp_buf.len());

    let chain = ChainBuilder::new()
        .chain(Buffer::new_sized(req_buf, req_len))
        .chain(Buffer::new_sized(resp_buf, resp_len).flags(DescriptorFlags::WRITE_ONLY))
        .build();

    let written = futures::executor::block_on(queue.send(chain)) as usize;

    if written < core::mem::size_of::<FuseOutHeader>() {
        return Err(FuseTransportError::ShortResponse(written));
    }

    let mut result = vec![0u8; written];
    result.copy_from_slice(&resp_buf[..written]);

    Ok(result)
}

/// Build a FUSE request with typed args struct AND trailing data (for FUSE_WRITE).
pub fn build_request_with_data<T: Sized>(
    opcode: u32,
    nodeid: u64,
    unique: u64,
    args: &T,
    data: &[u8],
) -> Vec<u8> {
    let hdr_size = core::mem::size_of::<FuseInHeader>();
    let args_size = core::mem::size_of::<T>();
    let total_len = hdr_size + args_size + data.len();

    let header = FuseInHeader {
        len: total_len as u32,
        opcode,
        unique,
        nodeid,
        uid: 0,
        gid: 0,
        pid: 0,
        total_extlen: 0,
        padding: 0,
    };

    let mut buf = Vec::with_capacity(total_len);

    let hdr_bytes =
        unsafe { core::slice::from_raw_parts(&header as *const _ as *const u8, hdr_size) };
    buf.extend_from_slice(hdr_bytes);

    let args_bytes =
        unsafe { core::slice::from_raw_parts(args as *const T as *const u8, args_size) };
    buf.extend_from_slice(args_bytes);

    buf.extend_from_slice(data);

    buf
}

/// Parse a FUSE response header from raw bytes.
pub fn parse_response_header(data: &[u8]) -> Result<FuseOutHeader, FuseTransportError> {
    if data.len() < core::mem::size_of::<FuseOutHeader>() {
        return Err(FuseTransportError::ShortResponse(data.len()));
    }

    let header = unsafe { *(data.as_ptr() as *const FuseOutHeader) };

    if header.error < 0 {
        return Err(FuseTransportError::FuseError(header.error));
    }

    Ok(header)
}

/// Extract the response body (after the FuseOutHeader).
pub fn response_body(data: &[u8]) -> &[u8] {
    let hdr_size = core::mem::size_of::<FuseOutHeader>();
    if data.len() > hdr_size {
        &data[hdr_size..]
    } else {
        &[]
    }
}

/// Build a FUSE request buffer: header + args + optional name (null-terminated).
pub fn build_request(
    opcode: u32,
    nodeid: u64,
    unique: u64,
    args: &[u8],
    name: Option<&[u8]>,
) -> Vec<u8> {
    let hdr_size = core::mem::size_of::<FuseInHeader>();
    let name_len = name.map(|n| n.len() + 1).unwrap_or(0); // +1 for null terminator
    let total_len = hdr_size + args.len() + name_len;

    let header = FuseInHeader {
        len: total_len as u32,
        opcode,
        unique,
        nodeid,
        uid: 0,
        gid: 0,
        pid: 0,
        total_extlen: 0,
        padding: 0,
    };

    let mut buf = Vec::with_capacity(total_len);

    let hdr_bytes =
        unsafe { core::slice::from_raw_parts(&header as *const _ as *const u8, hdr_size) };
    buf.extend_from_slice(hdr_bytes);
    buf.extend_from_slice(args);

    if let Some(name) = name {
        buf.extend_from_slice(name);
        buf.push(0); // null terminator
    }

    buf
}

/// Build a FUSE request with typed args struct.
pub fn build_request_with_args<T: Sized>(
    opcode: u32,
    nodeid: u64,
    unique: u64,
    args: &T,
    name: Option<&[u8]>,
) -> Vec<u8> {
    let args_bytes = unsafe {
        core::slice::from_raw_parts(args as *const T as *const u8, core::mem::size_of::<T>())
    };
    build_request(opcode, nodeid, unique, args_bytes, name)
}

#[derive(Debug, thiserror::Error)]
pub enum FuseTransportError {
    #[error("failed to allocate DMA buffer")]
    DmaAlloc,
    #[error("response too short: {0} bytes")]
    ShortResponse(usize),
    #[error("FUSE error: {0}")]
    FuseError(i32),
    #[error("unexpected response size")]
    UnexpectedSize,
    #[error("request too large for pre-allocated buffer ({0} bytes)")]
    RequestTooLarge(usize),
}
