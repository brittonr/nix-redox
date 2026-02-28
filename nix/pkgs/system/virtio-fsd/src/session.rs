//! FUSE session management.
//!
//! Manages the FUSE session lifecycle, owns pre-allocated DMA buffers, and
//! provides typed operations over the raw virtqueue transport.
//!
//! ## DMA buffer ownership
//!
//! Two DMA buffers are allocated once during [`FuseSession::init`] and reused
//! for every subsequent FUSE operation. Buffer sizes are rounded to
//! power-of-two page counts by [`alloc_dma_buffer`], which avoids a Redox
//! kernel buddy allocator bug (see transport.rs module docs). With correct
//! sizing, the buffers can be safely dropped — no `ManuallyDrop` needed.
//!
//! - `req_buf`: holds outgoing request data (header + args + write payload).
//!   Sized to fit a FUSE_WRITE with `MAX_IO_SIZE` bytes of data.
//! - `resp_buf`: holds incoming response data (header + read payload).
//!   Sized to fit a FUSE_READ returning `MAX_IO_SIZE` bytes.
//!
//! Per-operation descriptor sizes are controlled via `Buffer::new_sized`,
//! so virtiofsd sees exactly the right length for each request — no
//! over-reading on FUSE_READ, no wasted I/O.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use common::dma::Dma;
use virtio_core::transport::Queue;

use crate::fuse::*;
use crate::transport::*;

/// A FUSE session over a virtio-fs request queue.
///
/// All methods take `&mut self` because they write into the shared DMA
/// buffers. The session is used single-threaded from the scheme event loop.
pub struct FuseSession<'a> {
    queue: Arc<Queue<'a>>,
    unique_counter: AtomicU64,
    max_readahead: u32,
    max_write: u32,

    /// Pre-allocated request DMA buffer. Sized for the largest possible
    /// request (FUSE_WRITE: header + FuseWriteIn + MAX_IO_SIZE), rounded
    /// up to power-of-two pages for safe kernel deallocation.
    req_buf: Dma<[u8]>,

    /// Pre-allocated response DMA buffer. Sized for the largest possible
    /// response (FUSE_READ: header + MAX_IO_SIZE), rounded up to
    /// power-of-two pages for safe kernel deallocation.
    resp_buf: Dma<[u8]>,
}

impl<'a> FuseSession<'a> {
    /// Initialize a FUSE session with the host virtiofsd.
    ///
    /// Allocates two DMA buffers that are reused for the lifetime of the
    /// driver. Buffer sizes are rounded to power-of-two page counts by
    /// `alloc_dma_buffer`, avoiding the kernel's phys_contiguous bug.
    /// The FUSE_INIT handshake itself uses these buffers.
    pub fn init(queue: Arc<Queue<'a>>) -> Result<Self, FuseTransportError> {
        let unique_counter = AtomicU64::new(1);

        // Pre-allocate DMA buffers at maximum sizes.
        //
        // Request: header(40) + largest args (FuseWriteIn=40) + MAX_IO_SIZE
        // Response: header(16) + MAX_IO_SIZE
        //
        // alloc_dma_buffer rounds these up to power-of-two page counts,
        // so the kernel's zeroed_phys_contiguous initializes ALL allocated
        // pages. This makes munmap/deallocation safe — no ManuallyDrop needed.
        let req_buf_size = core::mem::size_of::<FuseInHeader>()
            + core::mem::size_of::<FuseWriteIn>()
            + MAX_IO_SIZE;
        let resp_buf_size = core::mem::size_of::<FuseOutHeader>() + MAX_IO_SIZE;

        let mut req_buf = alloc_dma_buffer(req_buf_size)?;
        let resp_buf = alloc_dma_buffer(resp_buf_size)?;

        // Send FUSE_INIT
        let init_in = FuseInitIn {
            major: FUSE_KERNEL_VERSION,
            minor: FUSE_KERNEL_MINOR_VERSION,
            max_readahead: 1024 * 1024, // 1 MiB
            flags: 0,
            flags2: 0,
            unused: [0; 11],
        };

        let unique = unique_counter.fetch_add(1, Ordering::Relaxed);
        let req = build_request_with_args(
            FuseOpcode::Init as u32,
            0,
            unique,
            &init_in,
            None,
        );

        req_buf[..req.len()].copy_from_slice(&req);
        let resp = fuse_exchange(&queue, &req_buf, req.len(), &resp_buf, META_RESPONSE)?;

        let _hdr = parse_response_header(&resp)?;
        let body = response_body(&resp);

        if body.len() < core::mem::size_of::<FuseInitOut>() {
            return Err(FuseTransportError::UnexpectedSize);
        }

        let init_out = unsafe { *(body.as_ptr() as *const FuseInitOut) };

        log::info!(
            "virtio-fsd: FUSE init: version {}.{}, max_readahead={}, max_write={}",
            init_out.major,
            init_out.minor,
            init_out.max_readahead,
            init_out.max_write
        );

        if init_out.max_write as usize > MAX_IO_SIZE {
            log::warn!(
                "virtio-fsd: negotiated max_write ({}) exceeds buffer size ({}), large writes will fail",
                init_out.max_write,
                MAX_IO_SIZE
            );
        }

        Ok(Self {
            queue,
            unique_counter,
            max_readahead: init_out.max_readahead,
            max_write: init_out.max_write,
            req_buf,
            resp_buf,
        })
    }

    fn next_unique(&self) -> u64 {
        self.unique_counter.fetch_add(1, Ordering::Relaxed)
    }

    /// Copy a serialized request into the request DMA buffer and send it,
    /// expecting a metadata-sized response (4 KiB descriptor).
    fn meta_exchange(&mut self, req: &[u8]) -> Result<Vec<u8>, FuseTransportError> {
        if req.len() > self.req_buf.len() {
            return Err(FuseTransportError::RequestTooLarge(req.len()));
        }
        self.req_buf[..req.len()].copy_from_slice(req);
        fuse_exchange(
            &self.queue,
            &self.req_buf,
            req.len(),
            &self.resp_buf,
            META_RESPONSE,
        )
    }

    /// Copy a serialized request into the request DMA buffer and send it,
    /// expecting a data-sized response. The response descriptor is sized to
    /// exactly `header + data_size` so virtiofsd reads the right amount.
    fn data_exchange(
        &mut self,
        req: &[u8],
        data_size: usize,
    ) -> Result<Vec<u8>, FuseTransportError> {
        if req.len() > self.req_buf.len() {
            return Err(FuseTransportError::RequestTooLarge(req.len()));
        }
        let resp_len = core::mem::size_of::<FuseOutHeader>() + data_size;
        if resp_len > self.resp_buf.len() {
            return Err(FuseTransportError::RequestTooLarge(resp_len));
        }
        self.req_buf[..req.len()].copy_from_slice(req);
        fuse_exchange(
            &self.queue,
            &self.req_buf,
            req.len(),
            &self.resp_buf,
            resp_len,
        )
    }

    /// Copy a large request (with write data) into the request DMA buffer
    /// and send it, expecting a metadata-sized response.
    fn write_exchange(&mut self, req: &[u8]) -> Result<Vec<u8>, FuseTransportError> {
        if req.len() > self.req_buf.len() {
            return Err(FuseTransportError::RequestTooLarge(req.len()));
        }
        self.req_buf[..req.len()].copy_from_slice(req);
        fuse_exchange(
            &self.queue,
            &self.req_buf,
            req.len(),
            &self.resp_buf,
            META_RESPONSE,
        )
    }

    /// FUSE_LOOKUP: resolve a name in a directory to a node + attributes.
    pub fn lookup(&mut self, parent: u64, name: &str) -> Result<FuseEntryOut, FuseTransportError> {
        let req = build_request(
            FuseOpcode::Lookup as u32,
            parent,
            self.next_unique(),
            &[],
            Some(name.as_bytes()),
        );

        let resp = self.meta_exchange(&req)?;
        let _hdr = parse_response_header(&resp)?;
        let body = response_body(&resp);

        if body.len() < core::mem::size_of::<FuseEntryOut>() {
            return Err(FuseTransportError::UnexpectedSize);
        }

        Ok(unsafe { *(body.as_ptr() as *const FuseEntryOut) })
    }

    /// FUSE_GETATTR: get attributes of a node.
    pub fn getattr(&mut self, nodeid: u64) -> Result<FuseAttrOut, FuseTransportError> {
        let args = FuseGetattrIn {
            getattr_flags: 0,
            dummy: 0,
            fh: 0,
        };

        let req = build_request_with_args(
            FuseOpcode::Getattr as u32,
            nodeid,
            self.next_unique(),
            &args,
            None,
        );

        let resp = self.meta_exchange(&req)?;
        let _hdr = parse_response_header(&resp)?;
        let body = response_body(&resp);

        if body.len() < core::mem::size_of::<FuseAttrOut>() {
            return Err(FuseTransportError::UnexpectedSize);
        }

        Ok(unsafe { *(body.as_ptr() as *const FuseAttrOut) })
    }

    /// FUSE_OPEN: open a file (returns a file handle).
    pub fn open(&mut self, nodeid: u64, flags: u32) -> Result<FuseOpenOut, FuseTransportError> {
        let args = FuseOpenIn {
            flags,
            open_flags: 0,
        };

        let req = build_request_with_args(
            FuseOpcode::Open as u32,
            nodeid,
            self.next_unique(),
            &args,
            None,
        );

        let resp = self.meta_exchange(&req)?;
        let _hdr = parse_response_header(&resp)?;
        let body = response_body(&resp);

        if body.len() < core::mem::size_of::<FuseOpenOut>() {
            return Err(FuseTransportError::UnexpectedSize);
        }

        Ok(unsafe { *(body.as_ptr() as *const FuseOpenOut) })
    }

    /// FUSE_OPENDIR: open a directory (returns a file handle).
    pub fn opendir(&mut self, nodeid: u64) -> Result<FuseOpenOut, FuseTransportError> {
        let args = FuseOpenIn {
            flags: 0,
            open_flags: 0,
        };

        let req = build_request_with_args(
            FuseOpcode::Opendir as u32,
            nodeid,
            self.next_unique(),
            &args,
            None,
        );

        let resp = self.meta_exchange(&req)?;
        let _hdr = parse_response_header(&resp)?;
        let body = response_body(&resp);

        if body.len() < core::mem::size_of::<FuseOpenOut>() {
            return Err(FuseTransportError::UnexpectedSize);
        }

        Ok(unsafe { *(body.as_ptr() as *const FuseOpenOut) })
    }

    /// FUSE_READ: read data from an open file.
    ///
    /// The response descriptor is sized to exactly `header + size` bytes so
    /// virtiofsd reads exactly the requested amount from the host file.
    pub fn read(
        &mut self,
        nodeid: u64,
        fh: u64,
        offset: u64,
        size: u32,
    ) -> Result<Vec<u8>, FuseTransportError> {
        let args = FuseReadIn {
            fh,
            offset,
            size,
            read_flags: 0,
            lock_owner: 0,
            flags: 0,
            padding: 0,
        };

        let req = build_request_with_args(
            FuseOpcode::Read as u32,
            nodeid,
            self.next_unique(),
            &args,
            None,
        );

        let resp = self.data_exchange(&req, size as usize)?;
        let _hdr = parse_response_header(&resp)?;
        Ok(response_body(&resp).to_vec())
    }

    /// FUSE_READDIR: read directory entries.
    pub fn readdir(
        &mut self,
        nodeid: u64,
        fh: u64,
        offset: u64,
        size: u32,
    ) -> Result<Vec<DirEntry>, FuseTransportError> {
        let args = FuseReadIn {
            fh,
            offset,
            size,
            read_flags: 0,
            lock_owner: 0,
            flags: 0,
            padding: 0,
        };

        let req = build_request_with_args(
            FuseOpcode::Readdir as u32,
            nodeid,
            self.next_unique(),
            &args,
            None,
        );

        let resp = self.data_exchange(&req, size as usize)?;
        let _hdr = parse_response_header(&resp)?;
        parse_dirents(response_body(&resp))
    }

    /// FUSE_RELEASE: close an open file handle.
    pub fn release(&mut self, nodeid: u64, fh: u64) -> Result<(), FuseTransportError> {
        let args = FuseReleaseIn {
            fh,
            flags: 0,
            release_flags: 0,
            lock_owner: 0,
        };

        let req = build_request_with_args(
            FuseOpcode::Release as u32,
            nodeid,
            self.next_unique(),
            &args,
            None,
        );

        let resp = self.meta_exchange(&req)?;
        let _hdr = parse_response_header(&resp)?;
        Ok(())
    }

    /// FUSE_RELEASEDIR: close an open directory handle.
    pub fn releasedir(&mut self, nodeid: u64, fh: u64) -> Result<(), FuseTransportError> {
        let args = FuseReleaseIn {
            fh,
            flags: 0,
            release_flags: 0,
            lock_owner: 0,
        };

        let req = build_request_with_args(
            FuseOpcode::Releasedir as u32,
            nodeid,
            self.next_unique(),
            &args,
            None,
        );

        let resp = self.meta_exchange(&req)?;
        let _hdr = parse_response_header(&resp)?;
        Ok(())
    }

    /// FUSE_WRITE: write data to an open file.
    ///
    /// Data is packed into the request descriptor (header + FuseWriteIn + data).
    /// Returns the number of bytes actually written by the host.
    pub fn write(
        &mut self,
        nodeid: u64,
        fh: u64,
        offset: u64,
        data: &[u8],
    ) -> Result<u32, FuseTransportError> {
        let args = FuseWriteIn {
            fh,
            offset,
            size: data.len() as u32,
            write_flags: 0,
            lock_owner: 0,
            flags: 0,
            padding: 0,
        };

        let req = build_request_with_data(
            FuseOpcode::Write as u32,
            nodeid,
            self.next_unique(),
            &args,
            data,
        );

        let resp = self.write_exchange(&req)?;
        let _hdr = parse_response_header(&resp)?;
        let body = response_body(&resp);

        if body.len() < core::mem::size_of::<FuseWriteOut>() {
            return Err(FuseTransportError::UnexpectedSize);
        }

        let write_out = unsafe { *(body.as_ptr() as *const FuseWriteOut) };
        Ok(write_out.size)
    }

    /// FUSE_CREATE: atomically create and open a file.
    ///
    /// Returns (FuseEntryOut, FuseOpenOut) — the new node's attributes and
    /// file handle. On Redox, this is triggered by `openat` with O_CREAT.
    pub fn create(
        &mut self,
        parent: u64,
        name: &str,
        flags: u32,
        mode: u32,
    ) -> Result<(FuseEntryOut, FuseOpenOut), FuseTransportError> {
        let args = FuseCreateIn {
            flags,
            mode,
            umask: 0o022,
            open_flags: 0,
        };

        let req = build_request_with_args(
            FuseOpcode::Create as u32,
            parent,
            self.next_unique(),
            &args,
            Some(name.as_bytes()),
        );

        let resp = self.meta_exchange(&req)?;
        let _hdr = parse_response_header(&resp)?;
        let body = response_body(&resp);

        let entry_size = core::mem::size_of::<FuseEntryOut>();
        let open_size = core::mem::size_of::<FuseOpenOut>();

        if body.len() < entry_size + open_size {
            return Err(FuseTransportError::UnexpectedSize);
        }

        let entry = unsafe { *(body.as_ptr() as *const FuseEntryOut) };
        let open = unsafe { *(body[entry_size..].as_ptr() as *const FuseOpenOut) };

        Ok((entry, open))
    }

    /// FUSE_MKDIR: create a directory.
    pub fn mkdir(
        &mut self,
        parent: u64,
        name: &str,
        mode: u32,
    ) -> Result<FuseEntryOut, FuseTransportError> {
        let args = FuseMkdirIn {
            mode,
            umask: 0o022,
        };

        let req = build_request_with_args(
            FuseOpcode::Mkdir as u32,
            parent,
            self.next_unique(),
            &args,
            Some(name.as_bytes()),
        );

        let resp = self.meta_exchange(&req)?;
        let _hdr = parse_response_header(&resp)?;
        let body = response_body(&resp);

        if body.len() < core::mem::size_of::<FuseEntryOut>() {
            return Err(FuseTransportError::UnexpectedSize);
        }

        Ok(unsafe { *(body.as_ptr() as *const FuseEntryOut) })
    }

    /// FUSE_UNLINK: remove a file.
    pub fn unlink(&mut self, parent: u64, name: &str) -> Result<(), FuseTransportError> {
        let req = build_request(
            FuseOpcode::Unlink as u32,
            parent,
            self.next_unique(),
            &[],
            Some(name.as_bytes()),
        );

        let resp = self.meta_exchange(&req)?;
        let _hdr = parse_response_header(&resp)?;
        Ok(())
    }

    /// FUSE_RMDIR: remove a directory.
    pub fn rmdir(&mut self, parent: u64, name: &str) -> Result<(), FuseTransportError> {
        let req = build_request(
            FuseOpcode::Rmdir as u32,
            parent,
            self.next_unique(),
            &[],
            Some(name.as_bytes()),
        );

        let resp = self.meta_exchange(&req)?;
        let _hdr = parse_response_header(&resp)?;
        Ok(())
    }

    /// FUSE_SETATTR with FATTR_SIZE: truncate a file to a given length.
    pub fn truncate(
        &mut self,
        nodeid: u64,
        fh: u64,
        size: u64,
    ) -> Result<FuseAttrOut, FuseTransportError> {
        let args = FuseSetattrIn {
            valid: FATTR_SIZE | FATTR_FH,
            padding: 0,
            fh,
            size,
            lock_owner: 0,
            atime: 0,
            mtime: 0,
            ctime: 0,
            atimensec: 0,
            mtimensec: 0,
            ctimensec: 0,
            mode: 0,
            unused4: 0,
            uid: 0,
            gid: 0,
            unused5: 0,
        };

        let req = build_request_with_args(
            FuseOpcode::Setattr as u32,
            nodeid,
            self.next_unique(),
            &args,
            None,
        );

        let resp = self.meta_exchange(&req)?;
        let _hdr = parse_response_header(&resp)?;
        let body = response_body(&resp);

        if body.len() < core::mem::size_of::<FuseAttrOut>() {
            return Err(FuseTransportError::UnexpectedSize);
        }

        Ok(unsafe { *(body.as_ptr() as *const FuseAttrOut) })
    }

    /// FUSE_STATFS: get filesystem statistics.
    pub fn statfs(&mut self) -> Result<FuseStatfsOut, FuseTransportError> {
        let req = build_request(
            FuseOpcode::Statfs as u32,
            1,
            self.next_unique(),
            &[],
            None,
        );

        let resp = self.meta_exchange(&req)?;
        let _hdr = parse_response_header(&resp)?;
        let body = response_body(&resp);

        if body.len() < core::mem::size_of::<FuseStatfsOut>() {
            return Err(FuseTransportError::UnexpectedSize);
        }

        Ok(unsafe { *(body.as_ptr() as *const FuseStatfsOut) })
    }
}

/// Parsed directory entry.
#[derive(Debug, Clone)]
pub struct DirEntry {
    pub ino: u64,
    pub off: u64,
    pub typ: u32,
    pub name: String,
}

/// Parse FUSE_READDIR response body into directory entries.
fn parse_dirents(data: &[u8]) -> Result<Vec<DirEntry>, FuseTransportError> {
    let mut entries = Vec::new();
    let mut offset = 0;
    let dirent_size = core::mem::size_of::<FuseDirent>();

    while offset + dirent_size <= data.len() {
        let dirent = unsafe { &*(data[offset..].as_ptr() as *const FuseDirent) };

        let name_start = offset + dirent_size;
        let name_end = name_start + dirent.namelen as usize;

        if name_end > data.len() {
            break;
        }

        let name = String::from_utf8_lossy(&data[name_start..name_end]).to_string();

        entries.push(DirEntry {
            ino: dirent.ino,
            off: dirent.off,
            typ: dirent.typ,
            name,
        });

        offset += fuse_dirent_size(dirent.namelen as usize);
    }

    Ok(entries)
}
