//! Scheme handler for the build filesystem proxy.
//!
//! Implements `SchemeSync` to interpose on `file:` operations,
//! checking each request against the `AllowList` before forwarding
//! to the real filesystem.
//!
//! ## initnsmgr deadlock and the root_fd bypass
//!
//! On Redox, ALL `file:` I/O goes through `SYS_OPENAT(namespace_fd, ...)`
//! which routes through `initnsmgr`. initnsmgr is single-threaded — it
//! processes one request at a time. When the builder opens `file:/path`,
//! initnsmgr forwards the request to our proxy (blocking itself). If our
//! proxy then does `File::open(path)` (which goes through initnsmgr),
//! we get a circular deadlock: initnsmgr → proxy → initnsmgr.
//!
//! The fix: pre-open `/` before starting the proxy to get a raw fd that
//! points directly to redoxfs. Use `SYS_OPENAT(root_fd, path, ...)` for
//! all real file I/O — this goes directly to redoxfs through the kernel,
//! bypassing initnsmgr entirely.
//!
//! Only compiled on Redox (`#[cfg(target_os = "redox")]`).

use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write as IoWrite};
use std::os::unix::io::{AsRawFd, FromRawFd};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

use redox_scheme::scheme::SchemeSync;
use redox_scheme::{CallerCtx, OpenResult};
use syscall::data::Stat;
use syscall::dirent::DirentBuf;
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
    /// The real file descriptor (opened via root_fd, bypassing initnsmgr).
    pub real_file: File,
    /// Absolute path on the real filesystem.
    pub real_path: PathBuf,
    /// Scheme-relative path (what the builder sees).
    pub scheme_path: String,
    /// Whether writes are allowed.
    pub writable: bool,
    /// Cached file size.
    pub size: u64,
    /// Cached mode bits.
    pub mode: u32,
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

// ── Raw filesystem ops (bypass initnsmgr) ──────────────────────────────────

/// Open a path relative to a raw root fd, bypassing initnsmgr.
///
/// Uses `SYS_OPENAT(root_fd, path, flags)` which routes directly to
/// redoxfs through the kernel — no namespace manager involved.
fn raw_openat(root_fd: usize, path: &str, flags: usize) -> Result<usize> {
    // Strip leading '/' — openat paths are relative to the root fd.
    let clean = path.trim_start_matches('/');
    let fcntl_flags = flags & syscall::O_FCNTL_MASK;
    unsafe {
        syscall::syscall5(
            syscall::SYS_OPENAT,
            root_fd,
            clean.as_ptr() as usize,
            clean.len(),
            flags,
            fcntl_flags,
        )
    }
}

/// Stat a raw fd.
fn raw_fstat(fd: usize) -> Result<Stat> {
    let mut stat = Stat::default();
    let stat_ptr = &mut stat as *mut Stat as usize;
    let stat_size = core::mem::size_of::<Stat>();
    unsafe {
        syscall::syscall3(
            syscall::SYS_FSTAT,
            fd,
            stat_ptr,
            stat_size,
        )?;
    }
    Ok(stat)
}

/// Close a raw fd.
fn raw_close(fd: usize) {
    let _ = syscall::close(fd);
}

// ── Scheme Handler ─────────────────────────────────────────────────────────

/// The build filesystem proxy scheme handler.
///
/// Routes `file:` operations from the builder through the allow-list.
/// Real file I/O uses the pre-opened `root_fd` to bypass initnsmgr.
pub struct BuildFsHandler {
    /// The allow-list controlling which paths are accessible.
    pub allow_list: AllowList,
    /// Open handles: ID → ProxyHandle.
    pub handles: HashMap<usize, ProxyHandle>,
    /// Raw fd pointing to "/" on redoxfs.
    /// Opened before the proxy starts (while initnsmgr is free).
    /// All real file I/O uses `SYS_OPENAT(root_fd, ...)` to bypass initnsmgr.
    pub root_fd: usize,
}

impl BuildFsHandler {
    pub fn new(allow_list: AllowList, root_fd: usize) -> Self {
        Self {
            allow_list,
            handles: HashMap::new(),
            root_fd,
        }
    }

    /// Resolve a scheme path to an absolute filesystem path.
    fn resolve_path(&self, scheme_path: &str) -> PathBuf {
        let clean = scheme_path.trim_start_matches('/');
        PathBuf::from(format!("/{clean}"))
    }

    /// Check the allow-list for a path.
    ///
    /// Cannot use `fs::canonicalize()` — that goes through initnsmgr.
    /// We check the literal path only. Symlinks are followed by redoxfs
    /// when we open via `raw_openat`.
    fn check_with_symlink_resolution(&self, path: &Path) -> Permission {
        self.allow_list.check(path)
    }

    /// Open a real file via the root fd (bypassing initnsmgr).
    fn open_real_file(&self, path: &str, flags: usize) -> Result<(File, Stat)> {
        let raw_fd = raw_openat(self.root_fd, path, flags)?;
        let stat = match raw_fstat(raw_fd) {
            Ok(s) => s,
            Err(e) => {
                raw_close(raw_fd);
                return Err(e);
            }
        };
        let file = unsafe { File::from_raw_fd(raw_fd as i32) };
        Ok((file, stat))
    }
}

impl SchemeSync for BuildFsHandler {
    fn scheme_root(&mut self) -> Result<usize> {
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
        eprintln!("buildfs: openat {:?} perm={:?}", abs_path, perm);
        if perm == Permission::Denied {
            return Err(Error::new(EACCES));
        }

        let wants_write = {
            let mode = flags & O_ACCMODE;
            mode == O_WRONLY || mode == (O_WRONLY | 0x0001_0000)
                || flags & O_CREAT != 0
                || flags & O_TRUNC != 0
        };

        if wants_write && perm != Permission::ReadWrite {
            return Err(Error::new(EACCES));
        }

        let id = next_id();
        let scheme_path = path_str.to_string();

        // Build redoxfs-compatible flags for the real open.
        let redox_flags = if wants_write {
            let mut f = syscall::flag::O_RDWR;
            if flags & O_CREAT != 0 {
                f |= syscall::flag::O_CREAT;
            }
            if flags & O_TRUNC != 0 {
                f |= syscall::flag::O_TRUNC;
            }
            f
        } else {
            syscall::flag::O_RDONLY
        };

        // If O_DIRECTORY requested, open as directory.
        if flags & O_DIRECTORY != 0 {
            // Verify it exists as a directory via the root fd.
            match raw_openat(self.root_fd, path_str, syscall::flag::O_RDONLY | syscall::flag::O_DIRECTORY) {
                Ok(dir_fd) => {
                    raw_close(dir_fd);
                    self.handles.insert(
                        id,
                        ProxyHandle::Dir(DirHandle {
                            real_path: abs_path,
                            scheme_path,
                        }),
                    );
                    return Ok(OpenResult::ThisScheme {
                        number: id,
                        flags: NewFdFlags::POSITIONED,
                    });
                }
                Err(_) => return Err(Error::new(ENOTDIR)),
            }
        }

        // Open the real file via root_fd (bypasses initnsmgr).
        let (file, stat) = self.open_real_file(path_str, redox_flags).map_err(|e| {
            // Translate common errors.
            if e.errno == syscall::ENOENT as i32 {
                Error::new(ENOENT)
            } else if e.errno == syscall::EACCES as i32 {
                Error::new(EACCES)
            } else {
                e
            }
        })?;

        // Check if it's a directory.
        if stat.st_mode & syscall::MODE_DIR != 0 {
            drop(file); // Close the file fd.
            self.handles.insert(
                id,
                ProxyHandle::Dir(DirHandle {
                    real_path: abs_path,
                    scheme_path,
                }),
            );
        } else {
            self.handles.insert(
                id,
                ProxyHandle::File(FileHandle {
                    real_file: file,
                    real_path: abs_path,
                    scheme_path,
                    writable: wants_write,
                    size: stat.st_size,
                    mode: stat.st_mode as u32,
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
                eprintln!("buildfs: read id={} len={} off={} => {}", id, buf.len(), offset, n);
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
                let pos = offset + n as u64;
                if pos > fh.size {
                    fh.size = pos;
                }
                eprintln!("buildfs: write id={} len={} => {}", id, buf.len(), n);
                Ok(n)
            }
            Some(ProxyHandle::Dir(_)) => Err(Error::new(EISDIR)),
            None => Err(Error::new(EBADF)),
        }
    }

    fn fsize(&mut self, id: usize, _ctx: &CallerCtx) -> Result<u64> {
        eprintln!("buildfs: fsize id={}", id);
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
        eprintln!("buildfs: fstat id={}", id);
        match self.handles.get(&id) {
            Some(ProxyHandle::File(fh)) => {
                stat.st_size = fh.size;
                stat.st_mode = fh.mode as u16;
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
        buf: DirentBuf<&'buf mut [u8]>,
        _opaque_offset: u64,
    ) -> Result<DirentBuf<&'buf mut [u8]>> {
        match self.handles.get(&id) {
            Some(ProxyHandle::Dir(_)) => {
                // TODO: Implement directory listing via raw syscalls.
                // For now, return empty — exec doesn't need getdents.
                Ok(buf)
            }
            Some(ProxyHandle::File(_)) => Err(Error::new(ENOTDIR)),
            None => Err(Error::new(EBADF)),
        }
    }

    fn on_close(&mut self, id: usize) {
        eprintln!("buildfs: close id={}", id);
        self.handles.remove(&id);
    }
}

impl BuildFsHandler {
    /// Check if a directory entry should be visible in a listing.
    fn is_entry_visible(&self, child_path: &Path) -> bool {
        if self.allow_list.can_read(child_path) {
            return true;
        }
        for prefix in self.allow_list.all_prefixes() {
            if prefix.starts_with(child_path) {
                return true;
            }
        }
        false
    }
}
