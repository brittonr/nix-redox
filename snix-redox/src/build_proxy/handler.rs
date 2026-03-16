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
use std::os::unix::io::FromRawFd;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

use redox_scheme::scheme::SchemeSync;
use redox_scheme::{CallerCtx, OpenResult};
use syscall::data::Stat;
use syscall::dirent::DirentBuf;
use syscall::error::{Error, Result, EACCES, EBADF, EIO, EISDIR, ENOENT, ENOTDIR};
use syscall::flag::{O_ACCMODE, O_APPEND, O_CREAT, O_DIRECTORY, O_EXCL, O_RDONLY, O_RDWR, O_TRUNC, O_WRONLY};
use syscall::schemev2::NewFdFlags;

use super::allow_list::{AllowList, Permission};

// ── Flag Translation ───────────────────────────────────────────────────────

/// Translated open flags — the proxy's internal representation.
///
/// Maps every Redox open flag we care about into named booleans so the
/// handler never does raw bit-masking inline.
#[derive(Debug)]
pub struct OpenFlags {
    /// Builder wants to read the file (O_RDONLY or O_RDWR).
    pub read: bool,
    /// Builder wants to write the file (O_WRONLY or O_RDWR).
    pub write: bool,
    /// Create the file if it does not exist (O_CREAT).
    pub create: bool,
    /// Truncate the file to zero length on open (O_TRUNC).
    pub truncate: bool,
    /// Fail if the file already exists, used with O_CREAT (O_EXCL).
    pub exclusive: bool,
    /// Append mode — writes go to end of file (O_APPEND).
    pub append: bool,
    /// Open must be a directory (O_DIRECTORY).
    pub directory: bool,
}

/// Translate raw Redox open flags into the proxy's internal representation.
///
/// Redox flag values (from redox_syscall 0.7):
///   O_RDONLY    = 0x0001_0000
///   O_WRONLY    = 0x0002_0000
///   O_RDWR      = 0x0003_0000
///   O_APPEND    = 0x0008_0000
///   O_CREAT     = 0x0200_0000
///   O_TRUNC     = 0x0400_0000
///   O_EXCL      = 0x0800_0000
///   O_DIRECTORY = 0x1000_0000
///   O_ACCMODE   = O_RDONLY | O_WRONLY | O_RDWR
pub fn translate_open_flags(raw: usize) -> OpenFlags {
    let mode = raw & O_ACCMODE;
    OpenFlags {
        read: mode == O_RDONLY || mode == O_RDWR,
        write: mode == O_WRONLY || mode == O_RDWR,
        create: raw & O_CREAT != 0,
        truncate: raw & O_TRUNC != 0,
        exclusive: raw & O_EXCL != 0,
        append: raw & O_APPEND != 0,
        directory: raw & O_DIRECTORY != 0,
    }
}

impl OpenFlags {
    /// True if the operation needs write permission on the allow-list.
    pub fn wants_write(&self) -> bool {
        self.write || self.create || self.truncate
    }

    /// Build redoxfs-compatible flags for the real open via root_fd.
    pub fn to_real_flags(&self) -> usize {
        let mut f = if self.write {
            O_RDWR
        } else {
            O_RDONLY
        };
        if self.create {
            f |= O_CREAT;
        }
        if self.truncate {
            f |= O_TRUNC;
        }
        if self.exclusive {
            f |= O_EXCL;
        }
        if self.append {
            f |= O_APPEND;
        }
        if self.directory {
            f |= O_DIRECTORY;
        }
        f
    }
}

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
    /// Append mode — seek to end before each write.
    pub append: bool,
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

/// Create a directory relative to root_fd, bypassing initnsmgr.
///
/// Uses `SYS_OPENAT` with `O_CREAT | O_DIRECTORY`. On redoxfs, opening
/// with both flags creates the directory if it does not exist.
fn raw_mkdir(root_fd: usize, path: &str) -> Result<()> {
    let clean = path.trim_start_matches('/');
    let flags = O_CREAT | O_DIRECTORY;
    let fd = raw_openat(root_fd, clean, flags)?;
    raw_close(fd);
    Ok(())
}

/// Recursively create directories for `path` via root_fd.
///
/// Walks each component of `path` and calls `raw_mkdir` for each
/// intermediate directory. Only called for paths under writable
/// prefixes ($out, $TMPDIR) — never for read-only paths.
fn mkdir_p_via_root_fd(root_fd: usize, path: &str) {
    let clean = path.trim_start_matches('/');
    let mut built = String::new();
    for component in clean.split('/') {
        if component.is_empty() {
            continue;
        }
        if !built.is_empty() {
            built.push('/');
        }
        built.push_str(component);
        // Ignore errors — the dir may already exist, or we may lack
        // permission (which will surface when the actual open happens).
        let _ = raw_mkdir(root_fd, &built);
    }
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
        let oflags = translate_open_flags(flags);

        // Check allow-list.
        let perm = self.check_with_symlink_resolution(&abs_path);
        eprintln!("buildfs: openat {:?} flags={:?} perm={:?}", abs_path, oflags, perm);
        if perm == Permission::Denied {
            return Err(Error::new(EACCES));
        }

        if oflags.wants_write() && perm != Permission::ReadWrite {
            return Err(Error::new(EACCES));
        }

        let id = next_id();
        let scheme_path = path_str.to_string();
        let real_flags = oflags.to_real_flags();

        // If O_DIRECTORY requested, open as directory.
        if oflags.directory {
            // For writable paths with O_CREAT, create the directory.
            if oflags.create && perm == Permission::ReadWrite {
                mkdir_p_via_root_fd(self.root_fd, path_str);
            }
            match raw_openat(self.root_fd, path_str, O_RDONLY | O_DIRECTORY) {
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

        // When O_CREAT is set on a writable path, ensure parent dirs exist.
        // Cargo creates deep output structures like $out/lib/rustlib/.../lib/.
        if oflags.create && perm == Permission::ReadWrite {
            if let Some(parent) = Path::new(path_str).parent() {
                let parent_str = parent.to_string_lossy();
                if !parent_str.is_empty() {
                    mkdir_p_via_root_fd(self.root_fd, &parent_str);
                }
            }
        }

        // Open the real file via root_fd (bypasses initnsmgr).
        let (file, stat) = self.open_real_file(path_str, real_flags).map_err(|e| {
            if e.errno == syscall::ENOENT as i32 {
                Error::new(ENOENT)
            } else if e.errno == syscall::EACCES as i32 {
                Error::new(EACCES)
            } else {
                e
            }
        })?;

        // Check if it's actually a directory (e.g., opened without O_DIRECTORY flag).
        if stat.st_mode & syscall::MODE_DIR != 0 {
            drop(file);
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
                    writable: oflags.wants_write(),
                    append: oflags.append,
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
                // Append mode: ignore caller offset, seek to end.
                let write_offset = if fh.append {
                    fh.real_file
                        .seek(SeekFrom::End(0))
                        .map_err(|_| Error::new(EIO))?
                } else {
                    fh.real_file
                        .seek(SeekFrom::Start(offset))
                        .map_err(|_| Error::new(EIO))?;
                    offset
                };
                let n = fh.real_file.write(buf).map_err(|_| Error::new(EIO))?;
                let pos = write_offset + n as u64;
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
