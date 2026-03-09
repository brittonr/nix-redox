//! Handle table for the store scheme daemon.
//!
//! Maps handle IDs (returned to callers as file descriptors) to
//! underlying filesystem state. Each open file or directory through
//! the `store:` scheme gets a handle entry.

use std::collections::BTreeMap;
use std::fs;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

/// An open file handle.
pub struct FileHandle {
    /// The underlying file on the real filesystem.
    pub file: fs::File,
    /// Absolute filesystem path (e.g., `/nix/store/abc.../bin/rg`).
    pub real_path: PathBuf,
    /// Path relative to the store scheme (e.g., `abc.../bin/rg`).
    pub scheme_path: String,
    /// File size (cached from stat at open time).
    pub size: u64,
    /// Whether the file is executable.
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

/// The type of an open handle.
pub enum Handle {
    File(FileHandle),
    Dir(DirHandle),
}

/// Table of open handles with auto-incrementing IDs.
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

    /// Open a file and return a handle ID.
    pub fn open_file(
        &mut self,
        real_path: PathBuf,
        scheme_path: String,
    ) -> io::Result<usize> {
        let file = fs::File::open(&real_path)?;
        let meta = file.metadata()?;

        #[cfg(unix)]
        let executable = {
            use std::os::unix::fs::PermissionsExt;
            meta.permissions().mode() & 0o111 != 0
        };
        #[cfg(not(unix))]
        let executable = false;

        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        self.handles.insert(
            id,
            Handle::File(FileHandle {
                file,
                real_path,
                scheme_path,
                size: meta.len(),
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

        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
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
            Some(Handle::Dir(_)) => Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "cannot read from a directory handle",
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
            Some(Handle::Dir(_)) => Ok(0),
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
            None => None,
        }
    }

    /// Check if a handle is a directory.
    pub fn is_dir(&self, id: usize) -> Option<bool> {
        match self.handles.get(&id) {
            Some(Handle::File(_)) => Some(false),
            Some(Handle::Dir(_)) => Some(true),
            None => None,
        }
    }

    /// Get the real filesystem path for a handle.
    pub fn real_path(&self, id: usize) -> Option<&PathBuf> {
        match self.handles.get(&id) {
            Some(Handle::File(fh)) => Some(&fh.real_path),
            Some(Handle::Dir(dh)) => Some(&dh.real_path),
            None => None,
        }
    }

    /// List directory entries. Populates the cache on first call.
    pub fn list_dir(&mut self, id: usize) -> io::Result<&[DirEntryInfo]> {
        // Check it's a directory.
        match self.handles.get(&id) {
            Some(Handle::Dir(_)) => {}
            Some(Handle::File(_)) => {
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

    /// Close a handle, releasing resources.
    pub fn close(&mut self, id: usize) -> bool {
        self.handles.remove(&id).is_some()
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

    for entry in fs::read_dir(path)? {
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
    use std::io::Write;

    #[test]
    fn open_and_read_file() {
        let tmp = tempfile::tempdir().unwrap();
        let file_path = tmp.path().join("hello.txt");
        fs::write(&file_path, "Hello World!").unwrap();

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
    fn open_and_list_dir() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("mydir");
        fs::create_dir(&dir).unwrap();
        fs::write(dir.join("a.txt"), "alpha").unwrap();
        fs::write(dir.join("b.txt"), "bravo").unwrap();
        fs::create_dir(dir.join("sub")).unwrap();

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
        fs::write(&file_path, "data").unwrap();

        let mut table = HandleTable::new();
        let id = table
            .open_file(file_path, "test".to_string())
            .unwrap();

        assert_eq!(table.len(), 1);
        assert!(table.close(id));
        assert_eq!(table.len(), 0);

        // Double close returns false.
        assert!(!table.close(id));
    }

    #[test]
    fn handle_ids_increment() {
        let tmp = tempfile::tempdir().unwrap();
        let f1 = tmp.path().join("a");
        let f2 = tmp.path().join("b");
        fs::write(&f1, "a").unwrap();
        fs::write(&f2, "b").unwrap();

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
        fs::create_dir(&dir).unwrap();
        fs::write(dir.join("zzz"), "").unwrap();
        fs::write(dir.join("aaa"), "").unwrap();
        fs::write(dir.join("mmm"), "").unwrap();

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
        fs::create_dir(&dir).unwrap();
        fs::write(dir.join("x"), "").unwrap();

        let mut table = HandleTable::new();
        let id = table.open_dir(dir.clone(), "pkg".to_string()).unwrap();

        // First read populates cache.
        let entries1 = table.list_dir(id).unwrap();
        assert_eq!(entries1.len(), 1);

        // Add a file — but cache should not change.
        fs::write(dir.join("y"), "").unwrap();
        let entries2 = table.list_dir(id).unwrap();
        assert_eq!(entries2.len(), 1); // Still cached.
    }

    #[test]
    fn real_path_accessors() {
        let tmp = tempfile::tempdir().unwrap();
        let f = tmp.path().join("file");
        fs::write(&f, "data").unwrap();

        let mut table = HandleTable::new();
        let id = table.open_file(f.clone(), "pkg/file".to_string()).unwrap();

        assert_eq!(table.real_path(id), Some(&f));
        assert_eq!(table.real_path(999), None);
    }
}
