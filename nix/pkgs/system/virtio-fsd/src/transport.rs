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
//! `preadv2()` from the host file for FUSE_READ. The response buffer MUST be
//! sized to `sizeof(FuseOutHeader) + requested_read_size`, not a fixed large
//! value. For metadata operations, any reasonable size (e.g. 4096) works.
//!
//! ## DMA buffer lifetime
//!
//! DMA buffers are intentionally leaked (`core::mem::forget`) after each
//! request to work around a Redox kernel bug where rapid DMA deallocation
//! corrupts page frame reference counts (`deallocate_p2frame` panics).
//! This wastes ~12KB per metadata request and ~8KB per read chunk, but the
//! total is bounded by the number of FUSE operations during the session.

use std::sync::Arc;

use common::dma::Dma;
use virtio_core::spec::{Buffer, ChainBuilder, DescriptorFlags};
use virtio_core::transport::Queue;

use crate::fuse::{FuseInHeader, FuseOutHeader};

/// Response buffer size for metadata operations (LOOKUP, GETATTR, OPEN, etc.).
const META_RESPONSE: usize = 4096;

/// Send a FUSE request and wait for the response synchronously.
///
/// `request` — serialized FUSE request (FuseInHeader + args + optional name).
/// `max_response` — maximum expected response size (header + body).
fn fuse_request_inner(
    queue: &Queue<'_>,
    request: &[u8],
    max_response: usize,
) -> Result<Vec<u8>, FuseTransportError> {
    let req_dma = {
        let mut dma = unsafe {
            Dma::<[u8]>::zeroed_slice(request.len())
                .map_err(|_| FuseTransportError::DmaAlloc)?
                .assume_init()
        };
        dma.copy_from_slice(request);
        dma
    };

    let resp_dma = unsafe {
        Dma::<[u8]>::zeroed_slice(max_response)
            .map_err(|_| FuseTransportError::DmaAlloc)?
            .assume_init()
    };

    let chain = ChainBuilder::new()
        .chain(Buffer::new_unsized(&req_dma))
        .chain(Buffer::new_unsized(&resp_dma).flags(DescriptorFlags::WRITE_ONLY))
        .build();

    let written = futures::executor::block_on(queue.send(chain)) as usize;

    if written < core::mem::size_of::<FuseOutHeader>() {
        // Leak before returning error
        core::mem::forget(req_dma);
        core::mem::forget(resp_dma);
        return Err(FuseTransportError::ShortResponse(written));
    }

    let mut result = vec![0u8; written];
    result.copy_from_slice(&resp_dma[..written]);

    // Leak DMA buffers to avoid kernel panic in funmap.
    // See module-level docs for explanation.
    core::mem::forget(req_dma);
    core::mem::forget(resp_dma);

    Ok(result)
}

/// Send a FUSE metadata request (LOOKUP, GETATTR, OPEN, RELEASE, STATFS, etc.).
/// Uses a fixed 4KB response buffer.
pub fn fuse_meta_request(queue: &Queue<'_>, request: &[u8]) -> Result<Vec<u8>, FuseTransportError> {
    fuse_request_inner(queue, request, META_RESPONSE)
}

/// Send a FUSE data request (READ, READDIR) with a response buffer sized to
/// exactly `sizeof(FuseOutHeader) + data_size`. This is critical because
/// virtiofsd uses the descriptor size to determine how many bytes to read
/// from the host file.
pub fn fuse_data_request(
    queue: &Queue<'_>,
    request: &[u8],
    data_size: usize,
) -> Result<Vec<u8>, FuseTransportError> {
    let resp_size = core::mem::size_of::<FuseOutHeader>() + data_size;
    fuse_request_inner(queue, request, resp_size)
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
}
