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
use syscall::flag::O_DIRECTORY;
use syscall::schemev2::NewFdFlags;

use super::handles::{Handle};
use super::resolve::{self, ResolvedPath};
use super::{StoreDaemon, StoredConfig};

use serde_json;

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
    fn scheme_root(&mut self) -> Result<usize> {
        eprintln!("stored: scheme_root called");
        // Use unchecked — we can't call is_dir() during scheme registration
        // because the filesystem might not be fully accessible yet.
        let fs_path = std::path::PathBuf::from(&self.daemon.config.store_dir);
        let id = self
            .daemon
            .handles
            .open_dir_unchecked(fs_path, String::new())
            .map_err(|e| {
                eprintln!("stored: scheme_root: {e}");
                Error::new(EIO)
            })?;
        eprintln!("stored: scheme_root returning id={id}");
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

        let path = path.trim_matches('/');

        // Handle .control path for manifest notifications.
        if path == ".control" {
            let id = self.daemon.handles.open_control(".control".to_string());
            return Ok(OpenResult::ThisScheme {
                number: id,
                flags: NewFdFlags::POSITIONED,
            });
        }

        // Parse the scheme-relative path.
        let resolved = resolve::parse_scheme_path(path).map_err(|e| {
            eprintln!("stored: resolve error: {e}");
            Error::new(ENOENT)
        })?;

        match &resolved {
            ResolvedPath::Root => {

                // Use unchecked — avoid filesystem I/O that could deadlock
                // if /nix/store/ resolution routes through this scheme.
                let fs_path = std::path::PathBuf::from(&self.daemon.config.store_dir);
                let id = self
                    .daemon
                    .handles
                    .open_dir_unchecked(fs_path, String::new())
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
                // Resolve to filesystem path. Skip existence checks —
                // filesystem I/O from within the scheme handler blocks
                // the event loop and can cause hangs on Redox. Instead,
                // create handles optimistically and let errors surface
                // when the caller actually reads/lists.
                let fs_path = resolve::to_filesystem_path(
                    &resolved,
                    &self.daemon.config.store_dir,
                )
                .ok_or_else(|| Error::new(ENOENT))?;

                let scheme_path = path.to_string();

                // StorePathRoot is always a directory. SubPath might be
                // either a file or directory. Use O_DIRECTORY flag,
                // the resolved path variant, OR the manifest to decide.
                //
                // CRITICAL: Do NOT call is_dir() or fs::File::open() on
                // directories inside the event loop — on Redox, opening
                // a directory path as a file can hang the daemon because
                // the file: scheme request blocks the single-threaded
                // event loop indefinitely. Instead, consult the manifest
                // (pre-loaded in memory, no I/O) to determine the type.
                let open_as_dir = match &resolved {
                    ResolvedPath::StorePathRoot { .. } => true,
                    _ if flags & O_DIRECTORY != 0 => true,
                    ResolvedPath::SubPath { store_path_name, subpath } => {
                        // Check manifest: if the subpath matches a "dir"
                        // entry or is a prefix of deeper entries, it's a
                        // directory. Only fall through to file open for
                        // paths that the manifest says are files.
                        self.daemon.is_directory_in_manifest(
                            store_path_name, subpath,
                        )
                    }
                    _ => false,
                };

                if open_as_dir {
                    let id = self
                        .daemon
                        .handles
                        .open_dir_unchecked(fs_path, scheme_path)
                        .map_err(|e| {
                            eprintln!("stored: open dir: {e}");
                            Error::new(ENOENT)
                        })?;
                    Ok(OpenResult::ThisScheme {
                        number: id,
                        flags: NewFdFlags::POSITIONED,
                    })
                } else {
                    // Create a LAZY file handle — no filesystem I/O.
                    // The actual open is deferred until the first read().
                    // Metadata comes from the manifest (if available).
                    let (size, executable) = match &resolved {
                        ResolvedPath::SubPath { store_path_name, subpath } => {
                            self.daemon.file_metadata_from_manifest(
                                store_path_name, subpath,
                            )
                        }
                        _ => (0, false),
                    };
                    let id = self.daemon.handles.open_file_lazy(
                        fs_path,
                        scheme_path,
                        size,
                        executable,
                    );
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
        id: usize,
        buf: &[u8],
        _offset: u64,
        _fcntl_flags: u32,
        _ctx: &CallerCtx,
    ) -> Result<usize> {
        // Only .control handles are writable.
        self.daemon.handles.write(id, buf).map_err(|e| {
            eprintln!("stored: write({id}): {e}");
            Error::new(EACCES)
        })
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

    fn fevent(&mut self, id: usize, _flags: syscall::flag::EventFlags, _ctx: &CallerCtx) -> Result<syscall::flag::EventFlags> {
        match self.daemon.handles.handles.get(&id) {
            Some(Handle::File(_)) | Some(Handle::Dir(_)) => {
                Ok(syscall::flag::EventFlags::EVENT_READ)
            }
            Some(Handle::Control(_)) => {
                Ok(syscall::flag::EventFlags::EVENT_WRITE)
            }
            None => Err(Error::new(EBADF)),
        }
    }

    fn fstat(&mut self, id: usize, stat: &mut Stat, _ctx: &CallerCtx) -> Result<()> {
        match self.daemon.handles.handles.get(&id) {
            Some(Handle::Dir(_)) => {
                // Directory: return synthetic stat without filesystem I/O.
                stat.st_mode = 0o040555; // S_IFDIR | r-xr-xr-x
                stat.st_size = 0;
                stat.st_nlink = 2;
            }
            Some(Handle::File(fh)) => {
                // File: return synthetic stat from manifest metadata.
                let executable = fh.executable;
                stat.st_size = fh.size;
                stat.st_mode = if executable { 0o100555 } else { 0o100444 };
                stat.st_nlink = 1;
            }
            Some(Handle::Control(_)) => {
                stat.st_mode = 0o100222; // Write-only.
                stat.st_size = 0;
                stat.st_nlink = 1;
            }
            None => return Err(Error::new(EBADF)),
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
            // Directory within a store path. Use manifest to avoid
            // filesystem I/O (which hangs in Redox scheme daemons).
            // Parse the scheme path to get store_path_name and subpath.
            let resolved = resolve::parse_scheme_path(&scheme_path)
                .map_err(|e| {
                    eprintln!("stored: getdents parse error: {e}");
                    Error::new(ENOENT)
                })?;

            let (store_path_name, subpath) = match &resolved {
                resolve::ResolvedPath::StorePathRoot { store_path_name } =>
                    (store_path_name.as_str(), ""),
                resolve::ResolvedPath::SubPath { store_path_name, subpath } =>
                    (store_path_name.as_str(), subpath.as_str()),
                _ => return Ok(buf),
            };

            // Manifests are provided via .control notifications from
            // snix install (same pattern as profiled). No on-demand I/O.
            let entries = self.daemon.list_from_manifest(
                store_path_name,
                subpath,
            );

            if let Some(entries) = entries {
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
            } else {
                eprintln!("stored: no manifest for {store_path_name}");
                return Err(Error::new(ENOENT));
            }
        }

        Ok(buf)
    }

    fn on_close(&mut self, id: usize) {
        if let Some(Handle::Control(ch)) = self.daemon.handles.close(id) {
            if !ch.buffer.is_empty() {
                let command = String::from_utf8_lossy(&ch.buffer);
                // Parse JSON: { "storePath": "/nix/store/...", "files": [...] }
                match serde_json::from_str::<serde_json::Value>(&command) {
                    Ok(val) => {
                        let store_path = val.get("storePath")
                            .and_then(|v| v.as_str())
                            .unwrap_or("");
                        let store_path_name = store_path
                            .strip_prefix(&format!("{}/", self.daemon.config.store_dir))
                            .unwrap_or(store_path);

                        if let Some(files_val) = val.get("files") {
                            match serde_json::from_value::<Vec<crate::nar::ManifestEntry>>(
                                files_val.clone()
                            ) {
                                Ok(files) if !files.is_empty() => {
                                    eprintln!(
                                        "stored: received manifest for {} ({} entries)",
                                        store_path_name,
                                        files.len()
                                    );
                                    self.daemon.manifests.insert(
                                        store_path_name.to_string(),
                                        files,
                                    );
                                }
                                Ok(_) => {
                                    eprintln!("stored: received empty manifest for {store_path_name}");
                                }
                                Err(e) => {
                                    eprintln!("stored: failed to parse manifest: {e}");
                                }
                            }
                        }
                    }
                    Err(e) => {
                        eprintln!("stored: failed to parse control command: {e}");
                    }
                }
            }
        }
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
    let socket = match Socket::create() {
        Ok(s) => {
            eprintln!("stored: socket created successfully");
            s
        }
        Err(e) => {
            eprintln!("stored: Socket::create() failed: {e}");
            eprintln!("stored: this requires /scheme/namespace/scheme-creation-cap");
            return Err(format!("stored: Socket::create failed: {e}").into());
        }
    };

    eprintln!("stored: registering scheme 'store'...");
    match redox_scheme::scheme::register_sync_scheme(&socket, "store", &mut handler) {
        Ok(()) => eprintln!("stored: scheme 'store' registered"),
        Err(e) => {
            eprintln!("stored: register_sync_scheme failed: {e}");
            eprintln!("stored: error code: {:?}", e);
            return Err(format!("stored: registration failed: {e}").into());
        }
    }

    // Pre-open "/" to get a direct fd to redoxfs. Must be done BEFORE
    // setrens(0, 0) — after that, std::fs operations fail. The root_fd
    // allows the FileIoWorker to continue reading files via SYS_OPENAT.
    eprintln!("stored: pre-opening /");
    let root_file = std::fs::File::open("/").map_err(|e| {
        format!("stored: failed to open /: {e}")
    })?;
    let root_fd = {
        use std::os::unix::io::AsRawFd;
        root_file.as_raw_fd() as usize
    };
    eprintln!("stored: root_fd={root_fd}");

    // Update the FileIoWorker with the root_fd so it can bypass
    // the namespace after setrens. The worker was spawned with
    // root_fd=None during daemon construction — now that we have
    // the fd, restart the worker with it.
    handler.daemon.handles.io_worker = Some(
        crate::file_io_worker::FileIoWorker::spawn(Some(root_fd))
    );

    // Drop into null namespace. After this, no new scheme connections
    // can be opened. The already-open scheme socket and root_fd still
    // work (open fds survive setrens).
    eprintln!("stored: entering null namespace");
    libredox::call::setrens(0, 0).map_err(|e| {
        format!("stored: setrens(0, 0) failed: {e}")
    })?;

    // Keep root_file alive for the lifetime of the event loop — it
    // owns the fd that the FileIoWorker uses.
    let _root_file = root_file;

    // Main event loop.
    eprintln!("stored: entering event loop");
    loop {
        let req = match socket.next_request(SignalBehavior::Restart)? {
            None => {
                eprintln!("stored: socket closed");
                break;
            }
            Some(req) => req,
        };

        match req.kind() {
            RequestKind::Call(call_req) => {

                let response = call_req.handle_sync(&mut handler, &mut state);

                if !socket.write_response(response, SignalBehavior::Restart)? {
                    eprintln!("stored: write_response returned false");
                    break;
                }
            }
            RequestKind::OnClose { id } => {

                handler.on_close(id);
            }
            _ => {

                continue;
            }
        }
    }

    eprintln!("stored: shutting down");
    Ok(())
}
