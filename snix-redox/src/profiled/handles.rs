//! Handle table for the profile scheme daemon.
//!
//! Three handle types:
//!   - `FileHandle`: an open file resolved through the profile mapping
//!   - `DirHandle`: a directory (profile root, subdir, or scheme root)
//!   - `ControlHandle`: the `.control` write interface for mutations

use std::collections::BTreeMap;
use std::fs;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

/// An open file resolved through the profile.
pub struct FileHandle {
    /// Underlying file on the real filesystem.
    pub file: fs::File,
    /// Absolute filesystem path.
    pub real_path: PathBuf,
    /// Scheme-relative path (e.g., `default/bin/rg`).
    pub scheme_path: String,
    /// Cached file size.
    pub size: u64,
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
    next_id: AtomicUsize,
    handles: BTreeMap<usize, Handle>,
}

impl HandleTable {
    pub fn new() -> Self {
        Self {
            next_id: AtomicUsize::new(1),
            handles: BTreeMap::new(),
        }
    }

    /// Open a file resolved through the profile mapping.
    pub fn open_file(
        &mut self,
        real_path: PathBuf,
        scheme_path: String,
    ) -> io::Result<usize> {
        let file = fs::File::open(&real_path)?;
        let size = file.metadata()?.len();

        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        self.handles.insert(
            id,
            Handle::File(FileHandle {
                file,
                real_path,
                scheme_path,
                size,
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
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
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
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
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
    pub fn read(
        &mut self,
        id: usize,
        buf: &mut [u8],
        offset: u64,
    ) -> io::Result<usize> {
        match self.handles.get_mut(&id) {
            Some(Handle::File(fh)) => {
                fh.file.seek(SeekFrom::Start(offset))?;
                fh.file.read(buf)
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
        fs::write(&path, "hello").unwrap();

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
