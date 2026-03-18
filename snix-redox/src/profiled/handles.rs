//! Handle table for the profile scheme daemon.
//!
//! Three handle types:
//!   - `FileHandle`: an open file resolved through the profile mapping
//!   - `DirHandle`: a directory (profile root, subdir, or scheme root)
//!   - `ControlHandle`: the `.control` write interface for mutations

use std::collections::BTreeMap;
use std::io::{self};
use std::path::PathBuf;

use crate::file_io_worker::FileIoWorker;

/// Upper bound for handle IDs. The kernel reserves the top 4096
/// values of usize as error codes.
const MAX_HANDLE_ID: usize = usize::MAX - 4096;

/// An open file resolved through the profile.
///
/// Lazy: `content` is `None` until the first `read()` call. On first
/// read, file content is loaded via the I/O worker thread (which can
/// safely access the `file:` scheme). Subsequent reads are served
/// from the cached content.
pub struct FileHandle {
    /// Cached file content. `None` until first read.
    pub content: Option<Vec<u8>>,
    /// Absolute filesystem path.
    pub real_path: PathBuf,
    /// Scheme-relative path (e.g., `default/bin/rg`).
    pub scheme_path: String,
    /// Cached file size (from manifest).
    pub size: u64,
    /// Whether the file is executable (from manifest).
    pub executable: bool,
}

/// An open directory for listing.
pub struct DirHandle {
    /// Scheme-relative path (e.g., `default/bin`, `default`, or empty for root).
    pub scheme_path: String,
    /// Profile name (empty for scheme root).
    pub profile_name: String,
    /// Subpath within the profile (empty for profile root).
    pub subpath: String,
}

/// The `.control` write interface for a profile.
pub struct ControlHandle {
    /// Which profile this control handle is for.
    pub profile_name: String,
    /// Scheme-relative path.
    pub scheme_path: String,
    /// Accumulated write data (JSON command).
    pub buffer: Vec<u8>,
}

/// Handle variants.
pub enum Handle {
    File(FileHandle),
    Dir(DirHandle),
    Control(ControlHandle),
}

/// Table of open handles.
pub struct HandleTable {
    next_id: usize,
    handles: BTreeMap<usize, Handle>,
    pub io_worker: Option<FileIoWorker>,
}

impl HandleTable {
    pub fn new() -> Self {
        Self {
            next_id: 1,
            handles: BTreeMap::new(),
            io_worker: None,
        }
    }

    /// Create a handle table with a background I/O worker.
    pub fn with_io_worker(root_fd: Option<usize>) -> Self {
        Self {
            next_id: 1,
            handles: BTreeMap::new(),
            io_worker: Some(FileIoWorker::spawn(root_fd)),
        }
    }

    /// Allocate the next handle ID, wrapping within the valid range
    /// and skipping IDs that collide with open handles.
    fn alloc_id(&mut self) -> usize {
        loop {
            let id = self.next_id;
            if self.next_id >= MAX_HANDLE_ID {
                self.next_id = 1;
            } else {
                self.next_id += 1;
            }
            if id >= 1 && id <= MAX_HANDLE_ID && !self.handles.contains_key(&id) {
                return id;
            }
        }
    }

    /// Create a lazy file handle (NO filesystem I/O).
    ///
    /// Safe to call from within a Redox scheme event loop.
    pub fn open_file_lazy(
        &mut self,
        real_path: PathBuf,
        scheme_path: String,
        size: u64,
        executable: bool,
    ) -> usize {
        let id = self.alloc_id();
        self.handles.insert(
            id,
            Handle::File(FileHandle {
                content: None,
                real_path,
                scheme_path,
                size,
                executable,
            }),
        );
        id
    }

    /// Open a file eagerly (does filesystem I/O).
    ///
    /// ⚠️ NOT safe from within Redox scheme handlers. Use `open_file_lazy`.
    pub fn open_file(
        &mut self,
        real_path: PathBuf,
        scheme_path: String,
    ) -> io::Result<usize> {
        let data = std::fs::read(&real_path)?;
        let size = data.len() as u64;

        let id = self.alloc_id();
        self.handles.insert(
            id,
            Handle::File(FileHandle {
                content: Some(data),
                real_path,
                scheme_path,
                size,
                executable: false,
            }),
        );
        Ok(id)
    }

    /// Open a directory listing handle.
    pub fn open_dir(
        &mut self,
        scheme_path: String,
        profile_name: String,
        subpath: String,
    ) -> usize {
        let id = self.alloc_id();
        self.handles.insert(
            id,
            Handle::Dir(DirHandle {
                scheme_path,
                profile_name,
                subpath,
            }),
        );
        id
    }

    /// Open a control handle for a profile.
    pub fn open_control(&mut self, profile_name: String, scheme_path: String) -> usize {
        let id = self.alloc_id();
        self.handles.insert(
            id,
            Handle::Control(ControlHandle {
                profile_name,
                scheme_path,
                buffer: Vec::new(),
            }),
        );
        id
    }

    /// Read from a file handle.
    ///
    /// On first read, loads file content via the I/O worker thread
    /// (or direct I/O as fallback). Subsequent reads are from cache.
    pub fn read(
        &mut self,
        id: usize,
        buf: &mut [u8],
        offset: u64,
    ) -> io::Result<usize> {
        match self.handles.get_mut(&id) {
            Some(Handle::File(fh)) => {
                if fh.content.is_none() {
                    let path = fh.real_path.clone();
                    drop(fh);
                    let data = if let Some(ref worker) = self.io_worker {
                        worker.preload_file(&path)?
                    } else {
                        std::fs::read(&path)?
                    };
                    match self.handles.get_mut(&id) {
                        Some(Handle::File(fh)) => {
                            fh.size = data.len() as u64;
                            fh.content = Some(data);
                        }
                        _ => {
                            return Err(io::Error::new(
                                io::ErrorKind::NotFound,
                                format!("handle {id} vanished during load"),
                            ));
                        }
                    }
                }
                match self.handles.get(&id) {
                    Some(Handle::File(fh)) => {
                        let content = fh.content.as_ref().unwrap();
                        let start = offset as usize;
                        if start >= content.len() {
                            return Ok(0);
                        }
                        let available = &content[start..];
                        let n = available.len().min(buf.len());
                        buf[..n].copy_from_slice(&available[..n]);
                        Ok(n)
                    }
                    _ => Err(io::Error::new(
                        io::ErrorKind::NotFound,
                        format!("handle {id} vanished"),
                    )),
                }
            }
            Some(Handle::Dir(_)) | Some(Handle::Control(_)) => Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "cannot read from this handle type",
            )),
            None => Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("invalid handle: {id}"),
            )),
        }
    }

    /// Write to a control handle (accumulate data).
    pub fn write(&mut self, id: usize, data: &[u8]) -> io::Result<usize> {
        match self.handles.get_mut(&id) {
            Some(Handle::Control(ch)) => {
                ch.buffer.extend_from_slice(data);
                Ok(data.len())
            }
            Some(Handle::File(_)) | Some(Handle::Dir(_)) => Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "read-only handle",
            )),
            None => Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("invalid handle: {id}"),
            )),
        }
    }

    /// Get a handle reference.
    pub fn get(&self, id: usize) -> Option<&Handle> {
        self.handles.get(&id)
    }

    /// Get a mutable handle reference.
    pub fn get_mut(&mut self, id: usize) -> Option<&mut Handle> {
        self.handles.get_mut(&id)
    }

    /// Get the scheme-relative path for a handle.
    pub fn scheme_path(&self, id: usize) -> Option<&str> {
        match self.handles.get(&id) {
            Some(Handle::File(fh)) => Some(&fh.scheme_path),
            Some(Handle::Dir(dh)) => Some(&dh.scheme_path),
            Some(Handle::Control(ch)) => Some(&ch.scheme_path),
            None => None,
        }
    }

    /// Get file size (0 for non-file handles).
    pub fn file_size(&self, id: usize) -> Option<u64> {
        match self.handles.get(&id) {
            Some(Handle::File(fh)) => Some(fh.size),
            Some(Handle::Dir(_)) | Some(Handle::Control(_)) => Some(0),
            None => None,
        }
    }

    /// Close a handle, returning the removed handle.
    pub fn close(&mut self, id: usize) -> Option<Handle> {
        self.handles.remove(&id)
    }

    pub fn len(&self) -> usize {
        self.handles.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn open_and_read_file() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("test.txt");
        std::fs::write(&path, "hello").unwrap();

        let mut table = HandleTable::new();
        let id = table
            .open_file(path, "default/bin/test".to_string())
            .unwrap();

        assert_eq!(table.file_size(id), Some(5));
        assert_eq!(table.scheme_path(id), Some("default/bin/test"));

        let mut buf = [0u8; 32];
        let n = table.read(id, &mut buf, 0).unwrap();
        assert_eq!(&buf[..n], b"hello");
    }

    #[test]
    fn control_handle_accumulates() {
        let mut table = HandleTable::new();
        let id = table.open_control("default".to_string(), "default/.control".to_string());

        table.write(id, b"{\"action\":").unwrap();
        table.write(id, b"\"add\"}").unwrap();

        match table.get(id) {
            Some(Handle::Control(ch)) => {
                assert_eq!(ch.buffer, b"{\"action\":\"add\"}");
            }
            _ => panic!("expected control handle"),
        }
    }

    #[test]
    fn dir_handle_no_read() {
        let mut table = HandleTable::new();
        let id = table.open_dir(
            "default/bin".to_string(),
            "default".to_string(),
            "bin".to_string(),
        );

        let mut buf = [0u8; 32];
        assert!(table.read(id, &mut buf, 0).is_err());
    }

    #[test]
    fn close_returns_handle() {
        let mut table = HandleTable::new();
        let id = table.open_control("test".to_string(), "test/.control".to_string());
        assert!(table.close(id).is_some());
        assert!(table.close(id).is_none()); // Double close.
    }
}
