//! Scheme handler for the build filesystem proxy.
//!
//! Implements `SchemeSync` to interpose on `file:` operations,
//! checking each request against the `AllowList` before forwarding
//! to the real filesystem via the parent's namespace.
//!
//! Only compiled on Redox (`#[cfg(target_os = "redox")]`).

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom, Write as IoWrite};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

use redox_scheme::scheme::SchemeSync;
use redox_scheme::{CallerCtx, OpenResult};
use syscall::data::Stat;
use syscall::dirent::{DirEntry as RedoxDirEntry, DirentBuf, DirentKind};
use syscall::error::{Error, Result, EACCES, EBADF, EIO, EISDIR, ENOENT, ENOTDIR};
use syscall::flag::{O_ACCMODE, O_CREAT, O_DIRECTORY, O_TRUNC, O_WRONLY};
use syscall::schemev2::NewFdFlags;

use super::allow_list::{AllowList, Permission};

/// Next handle ID. Global atomic counter — each open gets a unique ID.
static NEXT_HANDLE_ID: AtomicUsize = AtomicUsize::new(1);

fn next_id() -> usize {
    NEXT_HANDLE_ID.fetch_add(1, Ordering::Relaxed)
}

// ── Handle Types ───────────────────────────────────────────────────────────

/// An open file handle proxied to the real filesystem.
pub struct FileHandle {
    /// The real file descriptor (open in the parent's namespace).
    pub real_file: File,
    /// Absolute path on the real filesystem.
    pub real_path: PathBuf,
    /// Scheme-relative path (what the builder sees).
    pub scheme_path: String,
    /// Whether writes are allowed.
    pub writable: bool,
    /// Cached file size.
    pub size: u64,
    /// Whether the file is executable.
    pub executable: bool,
}

/// An open directory handle.
pub struct DirHandle {
    /// Absolute path on the real filesystem.
    pub real_path: PathBuf,
    /// Scheme-relative path (what the builder sees).
    pub scheme_path: String,
}

/// A proxy handle — either an open file or directory.
pub enum ProxyHandle {
    File(FileHandle),
    Dir(DirHandle),
}

// ── Scheme Handler ─────────────────────────────────────────────────────────

/// The build filesystem proxy scheme handler.
///
/// Routes `file:` operations from the builder through the allow-list.
/// Permitted operations are forwarded to the real filesystem using
/// the parent process's namespace (the proxy thread hasn't called
/// `setns`, so `std::fs` operations hit real redoxfs).
pub struct BuildFsHandler {
    /// The allow-list controlling which paths are accessible.
    pub allow_list: AllowList,
    /// Open handles: ID → ProxyHandle.
    pub handles: HashMap<usize, ProxyHandle>,
}

impl BuildFsHandler {
    pub fn new(allow_list: AllowList) -> Self {
        Self {
            allow_list,
            handles: HashMap::new(),
        }
    }

    /// Resolve a scheme path to an absolute filesystem path.
    ///
    /// The builder opens paths like `/nix/store/abc/lib/foo.so`.
    /// The scheme sees the path without the `file:` prefix, starting
    /// from `/`. We prepend nothing — the path is already absolute.
    fn resolve_path(&self, scheme_path: &str) -> PathBuf {
        let clean = scheme_path.trim_start_matches('/');
        PathBuf::from(format!("/{clean}"))
    }

    /// Check if a path resolves through symlinks to something allowed.
    ///
    /// NOTE: We cannot call `fs::canonicalize()` inside the scheme event
    /// loop — it does `file:` I/O which deadlocks the kernel (the kernel
    /// prevents any context in a scheme-socket-owning process from making
    /// `file:` requests). We only check the literal path against the
    /// allow-list. Symlink resolution happens implicitly when we open
    /// the real file (which must be done by a separate process, not a
    /// thread in the scheme daemon process).
    fn check_with_symlink_resolution(&self, path: &Path) -> Permission {
        self.allow_list.check(path)
    }
}

impl SchemeSync for BuildFsHandler {
    fn scheme_root(&mut self) -> Result<usize> {
        // The root of the `file:` scheme is `/`.
        let id = next_id();
        self.handles.insert(
            id,
            ProxyHandle::Dir(DirHandle {
                real_path: PathBuf::from("/"),
                scheme_path: String::new(),
            }),
        );
        Ok(id)
    }

    fn openat(
        &mut self,
        _dirfd: usize,
        path: &str,
        flags: usize,
        _fcntl_flags: u32,
        _ctx: &CallerCtx,
    ) -> Result<OpenResult> {
        let path_str = path.trim_matches('/');
        let abs_path = self.resolve_path(path_str);

        // Check allow-list.
        let perm = self.check_with_symlink_resolution(&abs_path);
        if perm == Permission::Denied {
            return Err(Error::new(EACCES));
        }

        let wants_write = {
            let mode = flags & O_ACCMODE;
            mode == O_WRONLY || mode == (O_WRONLY | 0x0001_0000) // O_RDWR on Redox
                || flags & O_CREAT != 0
                || flags & O_TRUNC != 0
        };

        // Block writes to read-only paths.
        if wants_write && perm != Permission::ReadWrite {
            return Err(Error::new(EACCES));
        }

        let id = next_id();
        let scheme_path = path_str.to_string();

        // Determine if this is a directory.
        let open_as_dir = flags & O_DIRECTORY != 0;

        // Check real filesystem metadata to decide file vs dir.
        // If the path doesn't exist yet (O_CREAT for $out), treat as file.
        let is_dir = if open_as_dir {
            true
        } else {
            match fs::symlink_metadata(&abs_path) {
                Ok(meta) => meta.is_dir(),
                Err(_) => false, // Doesn't exist yet — treat as file (O_CREAT).
            }
        };

        if is_dir {
            self.handles.insert(
                id,
                ProxyHandle::Dir(DirHandle {
                    real_path: abs_path,
                    scheme_path,
                }),
            );
        } else {
            // Open (or create) the real file.
            let real_file = if wants_write {
                fs::OpenOptions::new()
                    .read(true)
                    .write(true)
                    .create(flags & O_CREAT != 0)
                    .truncate(flags & O_TRUNC != 0)
                    .open(&abs_path)
            } else {
                File::open(&abs_path)
            };

            let real_file = real_file.map_err(|e| {
                match e.kind() {
                    std::io::ErrorKind::NotFound => Error::new(ENOENT),
                    std::io::ErrorKind::PermissionDenied => Error::new(EACCES),
                    _ => Error::new(EIO),
                }
            })?;

            let meta = real_file.metadata().map_err(|_| Error::new(EIO))?;
            let size = meta.len();
            #[cfg(unix)]
            let executable = {
                use std::os::unix::fs::PermissionsExt;
                meta.permissions().mode() & 0o111 != 0
            };
            #[cfg(not(unix))]
            let executable = false;

            self.handles.insert(
                id,
                ProxyHandle::File(FileHandle {
                    real_file,
                    real_path: abs_path,
                    scheme_path,
                    writable: wants_write,
                    size,
                    executable,
                }),
            );
        }

        Ok(OpenResult::ThisScheme {
            number: id,
            flags: NewFdFlags::POSITIONED,
        })
    }

    fn read(
        &mut self,
        id: usize,
        buf: &mut [u8],
        offset: u64,
        _fcntl_flags: u32,
        _ctx: &CallerCtx,
    ) -> Result<usize> {
        match self.handles.get_mut(&id) {
            Some(ProxyHandle::File(fh)) => {
                fh.real_file
                    .seek(SeekFrom::Start(offset))
                    .map_err(|_| Error::new(EIO))?;
                let n = fh.real_file.read(buf).map_err(|_| Error::new(EIO))?;
                Ok(n)
            }
            Some(ProxyHandle::Dir(_)) => Err(Error::new(EISDIR)),
            None => Err(Error::new(EBADF)),
        }
    }

    fn write(
        &mut self,
        id: usize,
        buf: &[u8],
        offset: u64,
        _fcntl_flags: u32,
        _ctx: &CallerCtx,
    ) -> Result<usize> {
        match self.handles.get_mut(&id) {
            Some(ProxyHandle::File(fh)) => {
                if !fh.writable {
                    return Err(Error::new(EACCES));
                }
                fh.real_file
                    .seek(SeekFrom::Start(offset))
                    .map_err(|_| Error::new(EIO))?;
                let n = fh.real_file.write(buf).map_err(|_| Error::new(EIO))?;
                // Update cached size.
                let pos = offset + n as u64;
                if pos > fh.size {
                    fh.size = pos;
                }
                Ok(n)
            }
            Some(ProxyHandle::Dir(_)) => Err(Error::new(EISDIR)),
            None => Err(Error::new(EBADF)),
        }
    }

    fn fsize(&mut self, id: usize, _ctx: &CallerCtx) -> Result<u64> {
        match self.handles.get(&id) {
            Some(ProxyHandle::File(fh)) => Ok(fh.size),
            Some(ProxyHandle::Dir(_)) => Ok(0),
            None => Err(Error::new(EBADF)),
        }
    }

    fn fpath(&mut self, id: usize, buf: &mut [u8], _ctx: &CallerCtx) -> Result<usize> {
        let scheme_path = match self.handles.get(&id) {
            Some(ProxyHandle::File(fh)) => &fh.scheme_path,
            Some(ProxyHandle::Dir(dh)) => &dh.scheme_path,
            None => return Err(Error::new(EBADF)),
        };

        // Return "file:/<path>" as the full scheme path.
        let full = if scheme_path.is_empty() {
            "file:/".to_string()
        } else {
            format!("file:/{scheme_path}")
        };

        let bytes = full.as_bytes();
        let len = bytes.len().min(buf.len());
        buf[..len].copy_from_slice(&bytes[..len]);
        Ok(len)
    }

    fn fstat(&mut self, id: usize, stat: &mut Stat, _ctx: &CallerCtx) -> Result<()> {
        match self.handles.get(&id) {
            Some(ProxyHandle::File(fh)) => {
                stat.st_size = fh.size;
                stat.st_mode = if fh.executable { 0o100555 } else { 0o100444 };
                if fh.writable {
                    stat.st_mode |= 0o200; // Add write bit.
                }
                stat.st_nlink = 1;
                Ok(())
            }
            Some(ProxyHandle::Dir(_)) => {
                stat.st_mode = 0o040555;
                stat.st_size = 0;
                stat.st_nlink = 2;
                Ok(())
            }
            None => Err(Error::new(EBADF)),
        }
    }

    fn getdents<'buf>(
        &mut self,
        id: usize,
        mut buf: DirentBuf<&'buf mut [u8]>,
        opaque_offset: u64,
    ) -> Result<DirentBuf<&'buf mut [u8]>> {
        let (real_path, _scheme_path) = match self.handles.get(&id) {
            Some(ProxyHandle::Dir(dh)) => (dh.real_path.clone(), dh.scheme_path.clone()),
            Some(ProxyHandle::File(_)) => return Err(Error::new(ENOTDIR)),
            None => return Err(Error::new(EBADF)),
        };

        // Read real directory entries.
        let entries = match fs::read_dir(&real_path) {
            Ok(iter) => iter,
            Err(_) => return Err(Error::new(EIO)),
        };

        // Collect and sort entries (NAR/Nix convention: sorted names).
        let mut all_entries: Vec<(String, bool, bool)> = Vec::new(); // (name, is_dir, is_symlink)
        for entry in entries {
            let entry = match entry {
                Ok(e) => e,
                Err(_) => continue,
            };
            let name = entry.file_name().to_string_lossy().into_owned();

            // Filter: check if this child path is allowed.
            let child_path = real_path.join(&name);
            if !self.is_entry_visible(&child_path) {
                continue;
            }

            let meta = entry.metadata();
            let is_dir = meta.as_ref().map(|m| m.is_dir()).unwrap_or(false);
            let is_symlink = entry
                .file_type()
                .map(|ft| ft.is_symlink())
                .unwrap_or(false);

            all_entries.push((name, is_dir, is_symlink));
        }
        all_entries.sort_by(|a, b| a.0.cmp(&b.0));

        let start = opaque_offset as usize;
        for (i, (name, is_dir, is_symlink)) in all_entries.iter().enumerate().skip(start) {
            let kind = if *is_dir {
                DirentKind::Directory
            } else if *is_symlink {
                DirentKind::Symlink
            } else {
                DirentKind::Regular
            };

            if buf
                .entry(RedoxDirEntry {
                    inode: 0,
                    next_opaque_id: (i + 1) as u64,
                    name: &name,
                    kind,
                })
                .is_err()
            {
                break;
            }
        }

        Ok(buf)
    }

    fn on_close(&mut self, id: usize) {
        // Remove the handle — the real File is dropped, closing the fd.
        self.handles.remove(&id);
    }
}

impl BuildFsHandler {
    /// Check if a directory entry should be visible in a listing.
    ///
    /// An entry is visible if:
    /// 1. It's directly on the allow-list, OR
    /// 2. It's a prefix of something on the allow-list (e.g., `/nix`
    ///    is visible because `/nix/store/abc` is allowed), OR
    /// 3. It's a child of something on the allow-list (e.g.,
    ///    `/nix/store/abc/lib` is visible because `/nix/store/abc`
    ///    is allowed).
    fn is_entry_visible(&self, child_path: &Path) -> bool {
        // Case 1 & 3: child is equal to or under an allow-list entry.
        if self.allow_list.can_read(child_path) {
            return true;
        }

        // Case 2: child is a PREFIX of an allow-list entry.
        // Example: listing "/" should show "nix" because /nix/store/abc is allowed.
        for prefix in self.allow_list.all_prefixes() {
            if prefix.starts_with(child_path) {
                return true;
            }
        }

        false
    }
}
