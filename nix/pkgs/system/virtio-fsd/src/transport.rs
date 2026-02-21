//! FUSE-over-virtqueue transport layer.
//!
//! Sends FUSE requests via the virtio request queue and receives FUSE responses.
//! The virtio-fs device has two queue types:
//!   - Queue 0: hiprio (for FUSE_FORGET, FUSE_BATCH_FORGET — no response expected)
//!   - Queues 1..N: request queues (normal FUSE request/response pairs)
//!
//! Each request is a chain of descriptors:
//!   [request header + args] → [response header + data (WRITE_ONLY)]

use std::sync::Arc;

use common::dma::Dma;
use virtio_core::spec::{Buffer, ChainBuilder, DescriptorFlags};
use virtio_core::transport::Queue;

use crate::fuse::{FuseInHeader, FuseOutHeader};

/// Maximum FUSE request+response size. virtiofsd typically uses 1 MiB + headers.
const MAX_FUSE_RESPONSE: usize = 1024 * 1024 + 4096;

/// Send a FUSE request and wait for the response synchronously.
///
/// `request` contains the serialized FUSE request (FuseInHeader + args + optional name).
/// Returns the raw response bytes (FuseOutHeader + response body).
pub fn fuse_request(queue: &Queue<'_>, request: &[u8]) -> Result<Vec<u8>, FuseTransportError> {
    // Allocate DMA buffers for the request and response.
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
        Dma::<[u8]>::zeroed_slice(MAX_FUSE_RESPONSE)
            .map_err(|_| FuseTransportError::DmaAlloc)?
            .assume_init()
    };

    // Build the descriptor chain:
    //   descriptor 0: request (device-readable)
    //   descriptor 1: response (device-writable)
    let chain = ChainBuilder::new()
        .chain(Buffer::new_unsized(&req_dma))
        .chain(Buffer::new_unsized(&resp_dma).flags(DescriptorFlags::WRITE_ONLY))
        .build();

    // Send and wait for completion.
    let written = futures::executor::block_on(queue.send(chain)) as usize;

    if written < core::mem::size_of::<FuseOutHeader>() {
        return Err(FuseTransportError::ShortResponse(written));
    }

    // Copy response out of DMA buffer.
    let mut result = vec![0u8; written];
    result.copy_from_slice(&resp_dma[..written]);

    Ok(result)
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

    // Write header
    let hdr_bytes =
        unsafe { core::slice::from_raw_parts(&header as *const _ as *const u8, hdr_size) };
    buf.extend_from_slice(hdr_bytes);

    // Write args
    buf.extend_from_slice(args);

    // Write null-terminated name
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
    let args_bytes =
        unsafe { core::slice::from_raw_parts(args as *const T as *const u8, core::mem::size_of::<T>()) };
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
