//! Handle table for the store scheme daemon.
//!
//! Maps handle IDs (returned to callers as file descriptors) to
//! underlying filesystem state. Each open file or directory through
//! the `store:` scheme gets a handle entry.
//!
//! File handles are LAZY: they record the path and metadata at open
//! time but defer the actual `fs::File::open()` until the first
//! `read()` call. This is critical on Redox where filesystem I/O
//! from within a scheme event loop hangs the daemon (the kernel
//! blocks the calling thread until the response arrives, but the
//! daemon can't process new requests while blocked).

use std::collections::BTreeMap;
use std::io::{self};
use std::path::PathBuf;

use crate::file_io_worker::FileIoWorker;

/// Upper bound for handle IDs. The kernel reserves the top 4096
/// values of usize as error codes, so valid descriptors are in
/// the range `1..=MAX_HANDLE_ID`.
const MAX_HANDLE_ID: usize = usize::MAX - 4096;

/// An open file handle.
///
/// Created lazily — `content` is `None` until the first `read()` call.
/// On first read, the file content is loaded via the I/O worker thread
/// (which can safely access the `file:` scheme without blocking the
/// scheme event loop). Subsequent reads are served from the cached content.
///
/// Metadata (size, executable) comes from the manifest at open time,
/// avoiding any filesystem I/O during the `openat` handler.
pub struct FileHandle {
    /// Cached file content. `None` until the first `read()` call.
    /// Populated by the I/O worker thread on first access.
    pub content: Option<Vec<u8>>,
    /// Absolute filesystem path (e.g., `/nix/store/abc.../bin/rg`).
    pub real_path: PathBuf,
    /// Path relative to the store scheme (e.g., `abc.../bin/rg`).
    pub scheme_path: String,
    /// File size (from manifest, or 0 if unknown).
    pub size: u64,
    /// Whether the file is executable (from manifest).
    pub executable: bool,
}

/// An open directory handle.
pub struct DirHandle {
    /// Absolute filesystem path.
    pub real_path: PathBuf,
    /// Path relative to the store scheme.
    pub scheme_path: String,
    /// Cached directory entries (populated on first readdir).
    pub entries: Option<Vec<DirEntryInfo>>,
}

/// A cached directory entry.
#[derive(Debug, Clone)]
pub struct DirEntryInfo {
    pub name: String,
    pub is_dir: bool,
    pub is_symlink: bool,
    pub size: u64,
}

/// A control handle for receiving manifest data notifications.
///
/// Accumulates written data in a buffer. On close, the buffer
/// is parsed as JSON containing manifest entries for a store path.
pub struct ControlHandle {
    /// Accumulated write buffer.
    pub buffer: Vec<u8>,
    /// Scheme-relative path (for fpath).
    pub scheme_path: String,
}

/// The type of an open handle.
pub enum Handle {
    File(FileHandle),
    Dir(DirHandle),
    Control(ControlHandle),
}

/// Table of open handles with auto-incrementing IDs.
///
/// Holds an optional `FileIoWorker` for servicing read requests
/// without blocking the scheme event loop. On Redox, the worker is
/// required; on other platforms (tests), reads fall back to direct I/O.
pub struct HandleTable {
    next_id: usize,
    pub handles: BTreeMap<usize, Handle>,
    /// Background I/O worker for file reads. On Redox, this MUST be set
    /// before any `read()` calls on lazy file handles.
    /// Public so StoreDaemon can use the worker for dynamic manifest loading.
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
    ///
    /// The worker thread handles all file reads, keeping filesystem
    /// I/O off the scheme event loop thread.
    pub fn with_io_worker(root_fd: Option<usize>) -> Self {
        Self {
            next_id: 1,
            handles: BTreeMap::new(),
            io_worker: Some(FileIoWorker::spawn(root_fd)),
        }
    }

    /// Allocate the next handle ID, wrapping within the valid range
    /// and skipping IDs that collide with open handles.
    ///
    /// Matches the upstream randd pattern: `Wrapping` counter with
    /// collision loop. Valid range is `1..=MAX_HANDLE_ID` (kernel
    /// reserves the top 4096 values as error codes).
    fn alloc_id(&mut self) -> usize {
        loop {
            let id = self.next_id;
            // Advance counter, wrapping back to 1 if past the valid range.
            if self.next_id >= MAX_HANDLE_ID {
                self.next_id = 1;
            } else {
                self.next_id += 1;
            }
            // Skip IDs already in use (collision after wrap).
            if id >= 1 && id <= MAX_HANDLE_ID && !self.handles.contains_key(&id) {
                return id;
            }
        }
    }

    /// Create a lazy file handle from manifest metadata (NO filesystem I/O).
    ///
    /// The actual `fs::File::open()` is deferred until the first `read()`.
    /// This is safe to call from within a Redox scheme event loop.
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

    /// Open a file and return a handle ID.
    ///
    /// ⚠️ Does filesystem I/O — NOT safe from within Redox scheme handlers.
    /// Use `open_file_lazy` instead for scheme daemon code.
    pub fn open_file(
        &mut self,
        real_path: PathBuf,
        scheme_path: String,
    ) -> io::Result<usize> {
        let data = std::fs::read(&real_path)?;
        let meta = std::fs::metadata(&real_path)?;

        #[cfg(unix)]
        let executable = {
            use std::os::unix::fs::PermissionsExt;
            meta.permissions().mode() & 0o111 != 0
        };
        #[cfg(not(unix))]
        let executable = false;

        let size = meta.len();
        let id = self.alloc_id();
        self.handles.insert(
            id,
            Handle::File(FileHandle {
                content: Some(data),
                real_path,
                scheme_path,
                size,
                executable,
            }),
        );
        Ok(id)
    }

    /// Open a directory and return a handle ID.
    pub fn open_dir(
        &mut self,
        real_path: PathBuf,
        scheme_path: String,
    ) -> io::Result<usize> {
        // Verify it's a directory.
        if !real_path.is_dir() {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("not a directory: {}", real_path.display()),
            ));
        }

        self.open_dir_unchecked(real_path, scheme_path)
    }

    /// Open a directory handle without filesystem verification.
    ///
    /// Used by scheme_root() and openat() where we know the path is valid
    /// but can't call is_dir() because it might deadlock (the daemon would
    /// recursively call itself through the filesystem).
    pub fn open_dir_unchecked(
        &mut self,
        real_path: PathBuf,
        scheme_path: String,
    ) -> io::Result<usize> {
        let id = self.alloc_id();
        self.handles.insert(
            id,
            Handle::Dir(DirHandle {
                real_path,
                scheme_path,
                entries: None,
            }),
        );
        Ok(id)
    }

    /// Read from a file handle at the given offset.
    ///
    /// On first read, the file content is loaded via the I/O worker
    /// thread (if available) or via direct I/O (for tests). The worker
    /// runs on a separate thread that can safely access the `file:`
    /// scheme without blocking the scheme event loop.
    ///
    /// Subsequent reads are served from the cached content buffer.
    pub fn read(
        &mut self,
        id: usize,
        buf: &mut [u8],
        offset: u64,
    ) -> io::Result<usize> {
        match self.handles.get_mut(&id) {
            Some(Handle::File(fh)) => {
                // Load content on first read.
                if fh.content.is_none() {
                    let path = fh.real_path.clone();
                    // Try I/O worker first (required on Redox to avoid
                    // blocking the scheme event loop). Fall back to direct
                    // I/O for tests and non-Redox platforms.
                    //
                    // We need to access self.io_worker, but we already
                    // have a mutable borrow on self.handles via `fh`.
                    // Extract what we need and re-borrow.
                    drop(fh);
                    let data = if let Some(ref worker) = self.io_worker {
                        worker.preload_file(&path)?
                    } else {
                        std::fs::read(&path)?
                    };
                    // Re-borrow the handle to store the loaded content.
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

                // Serve from cached content.
                match self.handles.get(&id) {
                    Some(Handle::File(fh)) => {
                        let content = fh.content.as_ref().unwrap();
                        let start = offset as usize;
                        if start >= content.len() {
                            return Ok(0); // EOF
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
                "cannot read from a directory/control handle",
            )),
            None => Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("invalid handle: {id}"),
            )),
        }
    }

    /// Get the size of a file handle.
    pub fn file_size(&self, id: usize) -> io::Result<u64> {
        match self.handles.get(&id) {
            Some(Handle::File(fh)) => Ok(fh.size),
            Some(Handle::Dir(_)) | Some(Handle::Control(_)) => Ok(0),
            None => Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("invalid handle: {id}"),
            )),
        }
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

    /// Check if a handle is a directory.
    pub fn is_dir(&self, id: usize) -> Option<bool> {
        match self.handles.get(&id) {
            Some(Handle::File(_)) | Some(Handle::Control(_)) => Some(false),
            Some(Handle::Dir(_)) => Some(true),
            None => None,
        }
    }

    /// Get the real filesystem path for a handle.
    pub fn real_path(&self, id: usize) -> Option<&PathBuf> {
        match self.handles.get(&id) {
            Some(Handle::File(fh)) => Some(&fh.real_path),
            Some(Handle::Dir(dh)) => Some(&dh.real_path),
            Some(Handle::Control(_)) => None,
            None => None,
        }
    }

    /// List directory entries. Populates the cache on first call.
    ///
    /// ⚠️ Does filesystem I/O — NOT safe from within Redox scheme handlers.
    /// The scheme handler uses `StoreDaemon::list_from_manifest()` instead.
    pub fn list_dir(&mut self, id: usize) -> io::Result<&[DirEntryInfo]> {
        // Check it's a directory.
        match self.handles.get(&id) {
            Some(Handle::Dir(_)) => {}
            Some(Handle::File(_)) | Some(Handle::Control(_)) => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "not a directory",
                ))
            }
            None => {
                return Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    format!("invalid handle: {id}"),
                ))
            }
        }

        // Populate entries if not cached.
        if let Some(Handle::Dir(dh)) = self.handles.get(&id) {
            if dh.entries.is_none() {
                let path = dh.real_path.clone();
                let entries = read_dir_entries(&path)?;
                if let Some(Handle::Dir(dh)) = self.handles.get_mut(&id) {
                    dh.entries = Some(entries);
                }
            }
        }

        match self.handles.get(&id) {
            Some(Handle::Dir(dh)) => Ok(dh.entries.as_deref().unwrap_or(&[])),
            _ => unreachable!(),
        }
    }

    /// Open a control handle for receiving manifest notifications.
    pub fn open_control(&mut self, scheme_path: String) -> usize {
        let id = self.alloc_id();
        self.handles.insert(
            id,
            Handle::Control(ControlHandle {
                buffer: Vec::new(),
                scheme_path,
            }),
        );
        id
    }

    /// Write data to a control handle buffer.
    pub fn write(&mut self, id: usize, buf: &[u8]) -> io::Result<usize> {
        match self.handles.get_mut(&id) {
            Some(Handle::Control(ch)) => {
                ch.buffer.extend_from_slice(buf);
                Ok(buf.len())
            }
            Some(_) => Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "store is read-only (use .control for notifications)",
            )),
            None => Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("invalid handle: {id}"),
            )),
        }
    }

    /// Close a handle, returning the control handle if it was one.
    /// The caller should process any accumulated control data.
    pub fn close(&mut self, id: usize) -> Option<Handle> {
        self.handles.remove(&id)
    }

    /// Number of open handles.
    pub fn len(&self) -> usize {
        self.handles.len()
    }

    /// Check if the table is empty.
    pub fn is_empty(&self) -> bool {
        self.handles.is_empty()
    }
}

/// Read directory entries from the filesystem.
fn read_dir_entries(path: &std::path::Path) -> io::Result<Vec<DirEntryInfo>> {
    let mut entries = Vec::new();

    for entry in std::fs::read_dir(path)? {
        let entry = entry?;
        let meta = entry.metadata()?;
        let file_type = entry.file_type()?;

        entries.push(DirEntryInfo {
            name: entry.file_name().to_string_lossy().to_string(),
            is_dir: file_type.is_dir(),
            is_symlink: file_type.is_symlink(),
            size: meta.len(),
        });
    }

    entries.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(entries)
}

// ── Tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn open_and_read_file() {
        let tmp = tempfile::tempdir().unwrap();
        let file_path = tmp.path().join("hello.txt");
        std::fs::write(&file_path, "Hello World!").unwrap();

        let mut table = HandleTable::new();
        let id = table
            .open_file(file_path, "abc-pkg/hello.txt".to_string())
            .unwrap();

        assert_eq!(table.file_size(id).unwrap(), 12);
        assert_eq!(table.scheme_path(id), Some("abc-pkg/hello.txt"));
        assert_eq!(table.is_dir(id), Some(false));

        let mut buf = [0u8; 64];
        let n = table.read(id, &mut buf, 0).unwrap();
        assert_eq!(&buf[..n], b"Hello World!");

        // Read at offset
        let n = table.read(id, &mut buf, 6).unwrap();
        assert_eq!(&buf[..n], b"World!");
    }

    #[test]
    fn lazy_file_handle() {
        let tmp = tempfile::tempdir().unwrap();
        let file_path = tmp.path().join("lazy.txt");
        std::fs::write(&file_path, "Lazy content").unwrap();

        let mut table = HandleTable::new();
        let id = table.open_file_lazy(
            file_path,
            "pkg/lazy.txt".to_string(),
            12, // size from manifest
            false,
        );

        // Metadata available immediately (from manifest).
        assert_eq!(table.file_size(id).unwrap(), 12);
        assert_eq!(table.scheme_path(id), Some("pkg/lazy.txt"));
        assert_eq!(table.is_dir(id), Some(false));

        // File not opened yet — first read triggers the open.
        let mut buf = [0u8; 64];
        let n = table.read(id, &mut buf, 0).unwrap();
        assert_eq!(&buf[..n], b"Lazy content");
    }

    #[test]
    fn lazy_file_nonexistent() {
        let mut table = HandleTable::new();
        let id = table.open_file_lazy(
            PathBuf::from("/nonexistent/path"),
            "bad".to_string(),
            0,
            false,
        );

        // Handle exists (metadata only), but read will fail
        // because the worker (or direct fallback) can't open the file.
        assert_eq!(table.is_dir(id), Some(false));
        let mut buf = [0u8; 64];
        assert!(table.read(id, &mut buf, 0).is_err());
    }

    #[test]
    fn open_and_list_dir() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("mydir");
        std::fs::create_dir(&dir).unwrap();
        std::fs::write(dir.join("a.txt"), "alpha").unwrap();
        std::fs::write(dir.join("b.txt"), "bravo").unwrap();
        std::fs::create_dir(dir.join("sub")).unwrap();

        let mut table = HandleTable::new();
        let id = table
            .open_dir(dir, "abc-pkg".to_string())
            .unwrap();

        assert_eq!(table.is_dir(id), Some(true));

        let entries = table.list_dir(id).unwrap();
        assert_eq!(entries.len(), 3);
        assert_eq!(entries[0].name, "a.txt");
        assert!(!entries[0].is_dir);
        assert_eq!(entries[1].name, "b.txt");
        assert!(!entries[1].is_dir);
        assert_eq!(entries[2].name, "sub");
        assert!(entries[2].is_dir);
    }

    #[test]
    fn close_handle() {
        let tmp = tempfile::tempdir().unwrap();
        let file_path = tmp.path().join("test.txt");
        std::fs::write(&file_path, "data").unwrap();

        let mut table = HandleTable::new();
        let id = table
            .open_file(file_path, "test".to_string())
            .unwrap();

        assert_eq!(table.len(), 1);
        assert!(table.close(id).is_some());
        assert_eq!(table.len(), 0);

        // Double close returns None.
        assert!(table.close(id).is_none());
    }

    #[test]
    fn handle_ids_increment() {
        let tmp = tempfile::tempdir().unwrap();
        let f1 = tmp.path().join("a");
        let f2 = tmp.path().join("b");
        std::fs::write(&f1, "a").unwrap();
        std::fs::write(&f2, "b").unwrap();

        let mut table = HandleTable::new();
        let id1 = table.open_file(f1, "a".to_string()).unwrap();
        let id2 = table.open_file(f2, "b".to_string()).unwrap();

        assert_ne!(id1, id2);
        assert!(id2 > id1);
    }

    #[test]
    fn read_invalid_handle() {
        let mut table = HandleTable::new();
        let mut buf = [0u8; 64];
        assert!(table.read(999, &mut buf, 0).is_err());
    }

    #[test]
    fn read_dir_handle_fails() {
        let tmp = tempfile::tempdir().unwrap();
        let mut table = HandleTable::new();
        let id = table
            .open_dir(tmp.path().to_path_buf(), "root".to_string())
            .unwrap();

        let mut buf = [0u8; 64];
        assert!(table.read(id, &mut buf, 0).is_err());
    }

    #[test]
    fn open_nonexistent_file() {
        let mut table = HandleTable::new();
        let result = table.open_file(
            PathBuf::from("/nonexistent/path"),
            "bad".to_string(),
        );
        assert!(result.is_err());
    }

    #[test]
    fn dir_entries_sorted() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("sorted");
        std::fs::create_dir(&dir).unwrap();
        std::fs::write(dir.join("zzz"), "").unwrap();
        std::fs::write(dir.join("aaa"), "").unwrap();
        std::fs::write(dir.join("mmm"), "").unwrap();

        let mut table = HandleTable::new();
        let id = table.open_dir(dir, "pkg".to_string()).unwrap();
        let entries = table.list_dir(id).unwrap();

        let names: Vec<&str> = entries.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, vec!["aaa", "mmm", "zzz"]);
    }

    #[test]
    fn dir_entries_cached() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("cached");
        std::fs::create_dir(&dir).unwrap();
        std::fs::write(dir.join("x"), "").unwrap();

        let mut table = HandleTable::new();
        let id = table.open_dir(dir.clone(), "pkg".to_string()).unwrap();

        // First read populates cache.
        let entries1 = table.list_dir(id).unwrap();
        assert_eq!(entries1.len(), 1);

        // Add a file — but cache should not change.
        std::fs::write(dir.join("y"), "").unwrap();
        let entries2 = table.list_dir(id).unwrap();
        assert_eq!(entries2.len(), 1); // Still cached.
    }

    #[test]
    fn real_path_accessors() {
        let tmp = tempfile::tempdir().unwrap();
        let f = tmp.path().join("file");
        std::fs::write(&f, "data").unwrap();

        let mut table = HandleTable::new();
        let id = table.open_file(f.clone(), "pkg/file".to_string()).unwrap();

        assert_eq!(table.real_path(id), Some(&f));
        assert_eq!(table.real_path(999), None);
    }

    #[test]
    fn handle_id_wraps_at_limit() {
        let mut table = HandleTable::new();
        // Force the counter near the limit.
        table.next_id = MAX_HANDLE_ID;
        let id1 = table.open_control("test1".to_string());
        assert_eq!(id1, MAX_HANDLE_ID);
        // Next allocation wraps to 1.
        let id2 = table.open_control("test2".to_string());
        assert_eq!(id2, 1);
    }

    #[test]
    fn handle_id_skips_collision() {
        let mut table = HandleTable::new();
        // Allocate ID 1.
        let id1 = table.open_control("a".to_string());
        assert_eq!(id1, 1);
        // Force counter back to 1 — should skip to 2.
        table.next_id = 1;
        let id2 = table.open_control("b".to_string());
        assert_eq!(id2, 2);
    }
}
