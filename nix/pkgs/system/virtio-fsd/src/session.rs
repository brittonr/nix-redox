//! FUSE session management.
//!
//! Manages the FUSE session lifecycle and provides typed operations
//! over the raw virtqueue transport.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use virtio_core::transport::Queue;

use crate::fuse::*;
use crate::transport::*;

/// A FUSE session over a virtio-fs request queue.
pub struct FuseSession<'a> {
    queue: Arc<Queue<'a>>,
    unique_counter: AtomicU64,
    max_readahead: u32,
    max_write: u32,
}

impl<'a> FuseSession<'a> {
    /// Initialize a FUSE session with the host virtiofsd.
    pub fn init(queue: Arc<Queue<'a>>) -> Result<Self, FuseTransportError> {
        let session = Self {
            queue,
            unique_counter: AtomicU64::new(1),
            max_readahead: 0,
            max_write: 0,
        };

        // Send FUSE_INIT
        let init_in = FuseInitIn {
            major: FUSE_KERNEL_VERSION,
            minor: FUSE_KERNEL_MINOR_VERSION,
            max_readahead: 1024 * 1024, // 1 MiB
            flags: 0,
            flags2: 0,
            unused: [0; 11],
        };

        let req = build_request_with_args(
            FuseOpcode::Init as u32,
            0,
            session.next_unique(),
            &init_in,
            None,
        );

        let resp = fuse_meta_request(&session.queue, &req)?;
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

        // Use interior mutability pattern — these are set once during init.
        // We keep them as regular fields since init returns an owned Self.
        let mut session = session;
        session.max_readahead = init_out.max_readahead;
        session.max_write = init_out.max_write;

        Ok(session)
    }

    fn next_unique(&self) -> u64 {
        self.unique_counter.fetch_add(1, Ordering::Relaxed)
    }

    /// FUSE_LOOKUP: resolve a name in a directory to a node + attributes.
    pub fn lookup(&self, parent: u64, name: &str) -> Result<FuseEntryOut, FuseTransportError> {
        let req = build_request(
            FuseOpcode::Lookup as u32,
            parent,
            self.next_unique(),
            &[],
            Some(name.as_bytes()),
        );

        let resp = fuse_meta_request(&self.queue, &req)?;
        let _hdr = parse_response_header(&resp)?;
        let body = response_body(&resp);

        if body.len() < core::mem::size_of::<FuseEntryOut>() {
            return Err(FuseTransportError::UnexpectedSize);
        }

        Ok(unsafe { *(body.as_ptr() as *const FuseEntryOut) })
    }

    /// FUSE_GETATTR: get attributes of a node.
    pub fn getattr(&self, nodeid: u64) -> Result<FuseAttrOut, FuseTransportError> {
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

        let resp = fuse_meta_request(&self.queue, &req)?;
        let _hdr = parse_response_header(&resp)?;
        let body = response_body(&resp);

        if body.len() < core::mem::size_of::<FuseAttrOut>() {
            return Err(FuseTransportError::UnexpectedSize);
        }

        Ok(unsafe { *(body.as_ptr() as *const FuseAttrOut) })
    }

    /// FUSE_OPEN: open a file (returns a file handle).
    pub fn open(&self, nodeid: u64, flags: u32) -> Result<FuseOpenOut, FuseTransportError> {
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

        let resp = fuse_meta_request(&self.queue, &req)?;
        let _hdr = parse_response_header(&resp)?;
        let body = response_body(&resp);

        if body.len() < core::mem::size_of::<FuseOpenOut>() {
            return Err(FuseTransportError::UnexpectedSize);
        }

        Ok(unsafe { *(body.as_ptr() as *const FuseOpenOut) })
    }

    /// FUSE_OPENDIR: open a directory (returns a file handle).
    pub fn opendir(&self, nodeid: u64) -> Result<FuseOpenOut, FuseTransportError> {
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

        let resp = fuse_meta_request(&self.queue, &req)?;
        let _hdr = parse_response_header(&resp)?;
        let body = response_body(&resp);

        if body.len() < core::mem::size_of::<FuseOpenOut>() {
            return Err(FuseTransportError::UnexpectedSize);
        }

        Ok(unsafe { *(body.as_ptr() as *const FuseOpenOut) })
    }

    /// FUSE_READ: read data from an open file.
    ///
    /// The response buffer is sized to exactly `header + size` bytes because
    /// virtiofsd uses the descriptor size to determine how many bytes to read
    /// from the host file.
    pub fn read(
        &self,
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

        let resp = fuse_data_request(&self.queue, &req, size as usize)?;
        let _hdr = parse_response_header(&resp)?;
        Ok(response_body(&resp).to_vec())
    }

    /// FUSE_READDIR: read directory entries.
    pub fn readdir(
        &self,
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

        let resp = fuse_data_request(&self.queue, &req, size as usize)?;
        let _hdr = parse_response_header(&resp)?;
        parse_dirents(response_body(&resp))
    }

    /// FUSE_RELEASE: close an open file handle.
    pub fn release(&self, nodeid: u64, fh: u64) -> Result<(), FuseTransportError> {
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

        let resp = fuse_meta_request(&self.queue, &req)?;
        let _hdr = parse_response_header(&resp)?;
        Ok(())
    }

    /// FUSE_RELEASEDIR: close an open directory handle.
    pub fn releasedir(&self, nodeid: u64, fh: u64) -> Result<(), FuseTransportError> {
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

        let resp = fuse_meta_request(&self.queue, &req)?;
        let _hdr = parse_response_header(&resp)?;
        Ok(())
    }

    /// FUSE_STATFS: get filesystem statistics.
    pub fn statfs(&self) -> Result<FuseStatfsOut, FuseTransportError> {
        let req = build_request(
            FuseOpcode::Statfs as u32,
            1,
            self.next_unique(),
            &[],
            None,
        );

        let resp = fuse_meta_request(&self.queue, &req)?;
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
