//! Redox scheme protocol implementation for `stored`.
//!
//! This module is only compiled on Redox (`#[cfg(target_os = "redox")]`).
//! It bridges the Redox kernel's scheme request protocol to the core
//! store daemon logic (handle table, path resolution, lazy extraction).
//!
//! Reference: `virtio-fsd/src/scheme.rs` for the established pattern.

use redox_scheme::scheme::{SchemeState, SchemeSync};
use redox_scheme::{CallerCtx, OpenResult, RequestKind, SignalBehavior, Socket};
use syscall::data::Stat;
use syscall::dirent::{DirEntry as RedoxDirEntry, DirentBuf, DirentKind};
use syscall::error::{Error, Result, EACCES, EBADF, EIO, ENOENT, ENOTDIR};
use syscall::flag::{O_DIRECTORY, O_STAT};
use syscall::schemev2::NewFdFlags;

use super::resolve::{self, ResolvedPath};
use super::{StoreDaemon, StoredConfig};

/// Scheme handler wrapping the core store daemon.
pub struct StoreSchemeHandler {
    daemon: StoreDaemon,
}

impl StoreSchemeHandler {
    fn new(daemon: StoreDaemon) -> Self {
        Self { daemon }
    }
}

impl SchemeSync for StoreSchemeHandler {
    fn openat(
        &mut self,
        _dirfd: usize,
        path: &str,
        flags: usize,
        _fcntl_flags: u32,
        _ctx: &CallerCtx,
    ) -> Result<OpenResult> {
        let path = path.trim_matches('/');

        // Parse the scheme-relative path.
        let resolved = resolve::parse_scheme_path(path).map_err(|e| {
            eprintln!("stored: resolve error: {e}");
            Error::new(ENOENT)
        })?;

        match &resolved {
            ResolvedPath::Root => {
                // Open the store root as a directory.
                let fs_path = std::path::PathBuf::from(&self.daemon.config.store_dir);
                let id = self
                    .daemon
                    .handles
                    .open_dir(fs_path, String::new())
                    .map_err(|e| {
                        eprintln!("stored: open root dir: {e}");
                        Error::new(EIO)
                    })?;
                Ok(OpenResult::ThisScheme {
                    number: id,
                    flags: NewFdFlags::POSITIONED,
                })
            }

            ResolvedPath::StorePathRoot { store_path_name }
            | ResolvedPath::SubPath {
                store_path_name, ..
            } => {
                // Verify registration in PathInfoDb (re-check on miss).
                if !resolve::is_registered(
                    &self.daemon.db,
                    store_path_name,
                    &self.daemon.config.store_dir,
                ) {
                    // Re-scan PathInfoDb in case the path was registered
                    // by `snix install` while we were running.
                    if let Ok(db) = crate::pathinfo::PathInfoDb::open() {
                        self.daemon.db = db;
                    }
                    if !resolve::is_registered(
                        &self.daemon.db,
                        store_path_name,
                        &self.daemon.config.store_dir,
                    ) {
                        return Err(Error::new(ENOENT));
                    }
                }

                // Lazy extraction if not yet on disk.
                if !resolve::is_extracted(
                    store_path_name,
                    &self.daemon.config.store_dir,
                ) {
                    super::lazy::ensure_extracted(
                        store_path_name,
                        &self.daemon.config.store_dir,
                        &self.daemon.config.cache_path,
                        &self.daemon.db,
                        &self.daemon.extracting,
                    )
                    .map_err(|e| {
                        eprintln!("stored: extraction failed: {e}");
                        Error::new(EIO)
                    })?;
                }

                // Resolve to filesystem path.
                let fs_path = resolve::to_filesystem_path(
                    &resolved,
                    &self.daemon.config.store_dir,
                )
                .ok_or_else(|| Error::new(ENOENT))?;

                if !fs_path.exists() {
                    return Err(Error::new(ENOENT));
                }

                // O_STAT: caller just wants metadata, open without reading.
                // O_DIRECTORY or actual directory: open as dir.
                let scheme_path = path.to_string();
                if fs_path.is_dir() || flags & O_DIRECTORY != 0 {
                    let id = self
                        .daemon
                        .handles
                        .open_dir(fs_path, scheme_path)
                        .map_err(|e| {
                            eprintln!("stored: open dir: {e}");
                            Error::new(ENOENT)
                        })?;
                    Ok(OpenResult::ThisScheme {
                        number: id,
                        flags: NewFdFlags::POSITIONED,
                    })
                } else {
                    let id = self
                        .daemon
                        .handles
                        .open_file(fs_path, scheme_path)
                        .map_err(|e| {
                            eprintln!("stored: open file: {e}");
                            Error::new(ENOENT)
                        })?;
                    Ok(OpenResult::ThisScheme {
                        number: id,
                        flags: NewFdFlags::POSITIONED,
                    })
                }
            }
        }
    }

    fn read(
        &mut self,
        id: usize,
        buf: &mut [u8],
        offset: u64,
        _fcntl_flags: u32,
        _ctx: &CallerCtx,
    ) -> Result<usize> {
        self.daemon.handles.read(id, buf, offset).map_err(|e| {
            eprintln!("stored: read({id}): {e}");
            Error::new(EBADF)
        })
    }

    fn write(
        &mut self,
        _id: usize,
        _buf: &[u8],
        _offset: u64,
        _fcntl_flags: u32,
        _ctx: &CallerCtx,
    ) -> Result<usize> {
        // Store is read-only.
        Err(Error::new(EACCES))
    }

    fn fsize(&mut self, id: usize, _ctx: &CallerCtx) -> Result<u64> {
        self.daemon.handles.file_size(id).map_err(|_| Error::new(EBADF))
    }

    fn fpath(&mut self, id: usize, buf: &mut [u8], _ctx: &CallerCtx) -> Result<usize> {
        let scheme_path = self
            .daemon
            .handles
            .scheme_path(id)
            .ok_or_else(|| Error::new(EBADF))?;

        let full = if scheme_path.is_empty() {
            "/scheme/store".to_string()
        } else {
            format!("/scheme/store/{scheme_path}")
        };

        let bytes = full.as_bytes();
        let len = bytes.len().min(buf.len());
        buf[..len].copy_from_slice(&bytes[..len]);
        Ok(len)
    }

    fn fstat(&mut self, id: usize, stat: &mut Stat, _ctx: &CallerCtx) -> Result<()> {
        let real_path = self
            .daemon
            .handles
            .real_path(id)
            .cloned()
            .ok_or_else(|| Error::new(EBADF))?;

        let meta = std::fs::metadata(&real_path).map_err(|_| Error::new(EIO))?;

        stat.st_size = meta.len();

        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            stat.st_mode = meta.mode() as u16;
            stat.st_uid = meta.uid();
            stat.st_gid = meta.gid();
            stat.st_ino = meta.ino();
            stat.st_nlink = meta.nlink() as u32;
            stat.st_blksize = meta.blksize() as u32;
            stat.st_blocks = meta.blocks();
            stat.st_atime = meta.atime() as u64;
            stat.st_atime_nsec = meta.atime_nsec() as u32;
            stat.st_mtime = meta.mtime() as u64;
            stat.st_mtime_nsec = meta.mtime_nsec() as u32;
            stat.st_ctime = meta.ctime() as u64;
            stat.st_ctime_nsec = meta.ctime_nsec() as u32;
        }

        // Set directory bit if it's a directory.
        if meta.is_dir() {
            stat.st_mode |= 0o040000; // S_IFDIR
        } else if meta.file_type().is_symlink() {
            stat.st_mode |= 0o120000; // S_IFLNK
        } else {
            stat.st_mode |= 0o100000; // S_IFREG
        }

        Ok(())
    }

    fn getdents<'buf>(
        &mut self,
        id: usize,
        mut buf: DirentBuf<&'buf mut [u8]>,
        opaque_offset: u64,
    ) -> Result<DirentBuf<&'buf mut [u8]>> {
        let is_dir = self.daemon.handles.is_dir(id).ok_or(Error::new(EBADF))?;
        if !is_dir {
            return Err(Error::new(ENOTDIR));
        }

        let scheme_path = self
            .daemon
            .handles
            .scheme_path(id)
            .unwrap_or("")
            .to_string();

        if scheme_path.is_empty() {
            // Root listing: show all registered store paths.
            let paths = resolve::list_store_paths(
                &self.daemon.db,
                &self.daemon.config.store_dir,
            )
            .map_err(|e| {
                eprintln!("stored: list_store_paths: {e}");
                Error::new(EIO)
            })?;

            let start = opaque_offset as usize;
            for (i, sp) in paths.iter().enumerate().skip(start) {
                if buf
                    .entry(RedoxDirEntry {
                        inode: 0,
                        next_opaque_id: (i + 1) as u64,
                        name: &sp.name,
                        kind: DirentKind::Directory,
                    })
                    .is_err()
                {
                    break;
                }
            }
        } else {
            // Directory within a store path.
            let entries = self.daemon.handles.list_dir(id).map_err(|e| {
                eprintln!("stored: list_dir({id}): {e}");
                Error::new(EIO)
            })?;

            let start = opaque_offset as usize;
            for (i, entry) in entries.iter().enumerate().skip(start) {
                let kind = if entry.is_dir {
                    DirentKind::Directory
                } else if entry.is_symlink {
                    DirentKind::Symlink
                } else {
                    DirentKind::Regular
                };

                if buf
                    .entry(RedoxDirEntry {
                        inode: 0,
                        next_opaque_id: (i + 1) as u64,
                        name: &entry.name,
                        kind,
                    })
                    .is_err()
                {
                    break;
                }
            }
        }

        Ok(buf)
    }

    fn on_close(&mut self, id: usize) {
        self.daemon.handles.close(id);
    }
}

/// Run the store scheme daemon (blocking).
///
/// Registers the `store` scheme with the Redox kernel, then enters
/// the main event loop processing scheme requests.
pub fn run_daemon(config: StoredConfig) -> Result<(), Box<dyn std::error::Error>> {
    eprintln!(
        "stored: initializing (cache={}, store={})",
        config.cache_path, config.store_dir
    );

    let daemon = StoreDaemon::new(config)?;
    let path_count = daemon.db.list_paths().map(|p| p.len()).unwrap_or(0);
    eprintln!("stored: PathInfoDb loaded ({path_count} paths)");

    let mut handler = StoreSchemeHandler::new(daemon);
    let mut state = SchemeState::new();

    // Register the `store` scheme with the kernel.
    eprintln!("stored: creating scheme socket...");
    let socket = Socket::create()?;

    eprintln!("stored: registering scheme 'store'...");
    redox_scheme::scheme::register_sync_scheme(&socket, "store", &mut handler)?;
    eprintln!("stored: scheme 'store' registered");

    // Main event loop.
    loop {
        let req = match socket.next_request(SignalBehavior::Restart)? {
            None => break,
            Some(req) => req,
        };

        match req.kind() {
            RequestKind::Call(call_req) => {
                let response = call_req.handle_sync(&mut handler, &mut state);
                if !socket.write_response(response, SignalBehavior::Restart)? {
                    break;
                }
            }
            RequestKind::OnClose { id } => {
                handler.on_close(id);
            }
            _ => continue,
        }
    }

    eprintln!("stored: shutting down");
    Ok(())
}
