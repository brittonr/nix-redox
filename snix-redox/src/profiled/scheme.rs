//! Redox scheme protocol implementation for `profiled`.
//!
//! Only compiled on Redox (`#[cfg(target_os = "redox")]`).
//! Bridges the kernel scheme protocol to the profile mapping logic.
//!
//! Path structure:
//!   `profile:`                    → list all profiles
//!   `profile:default/`            → list top-level dirs in profile
//!   `profile:default/bin/`        → union listing of bin/ across packages
//!   `profile:default/bin/rg`      → resolved file from a package
//!   `profile:default/.control`    → write JSON commands for mutations

use redox_scheme::scheme::{SchemeState, SchemeSync};
use redox_scheme::{CallerCtx, OpenResult, RequestKind, SignalBehavior, Socket};
use syscall::data::Stat;
use syscall::dirent::{DirEntry as RedoxDirEntry, DirentBuf, DirentKind};
use syscall::error::{Error, Result, EACCES, EBADF, EINVAL, EIO, ENOENT, ENOTDIR};
use syscall::flag::O_DIRECTORY;
use syscall::schemev2::NewFdFlags;

use super::handles::{Handle, HandleTable};
use super::mapping::ProfileStore;
use super::{ProfileDaemon, ProfiledConfig};

/// Scheme handler wrapping the profile daemon.
pub struct ProfileSchemeHandler {
    daemon: ProfileDaemon,
    handles: HandleTable,
}

impl ProfileSchemeHandler {
    fn new(daemon: ProfileDaemon) -> Self {
        Self {
            daemon,
            // root_fd set later by run_daemon() before setrens.
            handles: HandleTable::with_io_worker(None),
        }
    }

    /// Parse a scheme-relative path into (profile_name, subpath).
    /// Empty path = scheme root, "default" = profile root, "default/bin/rg" = subpath.
    fn parse_path(path: &str) -> (Option<&str>, &str) {
        let path = path.trim_matches('/');
        if path.is_empty() {
            return (None, "");
        }
        match path.find('/') {
            Some(pos) => (Some(&path[..pos]), &path[pos + 1..]),
            None => (Some(path), ""),
        }
    }
}

impl SchemeSync for ProfileSchemeHandler {
    fn scheme_root(&mut self) -> Result<usize> {
        // Open the scheme root (listing of all profiles).
        let id = self.handles.open_dir(
            String::new(),
            String::new(),
            String::new(),
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
        let path = path.trim_matches('/');
        let (profile_name, subpath) = Self::parse_path(path);

        match profile_name {
            None => {
                // Scheme root: list all profiles.
                let id = self.handles.open_dir(
                    String::new(),
                    String::new(),
                    String::new(),
                );
                Ok(OpenResult::ThisScheme {
                    number: id,
                    flags: NewFdFlags::POSITIONED,
                })
            }

            Some(name) => {
                // Check if this is the .control interface.
                if subpath == ".control" {
                    let id = self.handles.open_control(
                        name.to_string(),
                        path.to_string(),
                    );
                    Ok(OpenResult::ThisScheme {
                        number: id,
                        flags: NewFdFlags::POSITIONED,
                    })
                } else if subpath.is_empty() || flags & O_DIRECTORY != 0 {
                    // Profile root or explicit directory open.
                    let id = self.handles.open_dir(
                        path.to_string(),
                        name.to_string(),
                        subpath.to_string(),
                    );
                    Ok(OpenResult::ThisScheme {
                        number: id,
                        flags: NewFdFlags::POSITIONED,
                    })
                } else {
                    // Check if this is a directory path first (union of dirs
                    // across packages). Uses manifests to avoid filesystem I/O.
                    let mapping = self
                        .daemon
                        .profiles
                        .get(name)
                        .ok_or_else(|| Error::new(ENOENT))?;

                    let entries = mapping.list_union_from_manifests(
                        subpath,
                        &self.daemon.manifests,
                    );
                    if !entries.is_empty() {
                        // It's a directory — open as dir handle.
                        let id = self.handles.open_dir(
                            path.to_string(),
                            name.to_string(),
                            subpath.to_string(),
                        );
                        return Ok(OpenResult::ThisScheme {
                            number: id,
                            flags: NewFdFlags::POSITIONED,
                        });
                    }

                    // Try to resolve as a file through the profile mapping.
                    // resolve_path does filesystem I/O (exists check), but
                    // that's ok because it goes through file: scheme, not
                    // our profile: scheme. No self-deadlock.
                    // However, on Redox scheme daemons ALL filesystem I/O
                    // hangs. Use manifest-based resolution instead.
                    // Find the file and its metadata from manifests (no I/O).
                    let (full_path, size, executable) = {
                        let mut found = None;
                        for pkg in mapping.packages.iter().rev() {
                            if let Some(manifest) = self.daemon.manifests.get(&pkg.store_path) {
                                if let Some(entry) = manifest.iter().find(|e| e.path == subpath && e.entry_type == "file") {
                                    found = Some((
                                        std::path::PathBuf::from(&pkg.store_path).join(subpath),
                                        entry.size,
                                        entry.executable,
                                    ));
                                    break;
                                }
                            }
                        }
                        found.ok_or_else(|| Error::new(ENOENT))?
                    };

                    // Lazy file handle — no filesystem I/O during openat.
                    let id = self.handles.open_file_lazy(
                        full_path,
                        path.to_string(),
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
        self.handles.read(id, buf, offset).map_err(|e| {
            eprintln!("profiled: read({id}): {e}");
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
        self.handles.write(id, buf).map_err(|e| {
            eprintln!("profiled: write({id}): {e}");
            Error::new(EACCES)
        })
    }

    fn fsize(&mut self, id: usize, _ctx: &CallerCtx) -> Result<u64> {
        self.handles.file_size(id).ok_or_else(|| Error::new(EBADF))
    }

    fn fpath(&mut self, id: usize, buf: &mut [u8], _ctx: &CallerCtx) -> Result<usize> {
        let scheme_path = self
            .handles
            .scheme_path(id)
            .ok_or_else(|| Error::new(EBADF))?;

        let full = if scheme_path.is_empty() {
            "/scheme/profile".to_string()
        } else {
            format!("/scheme/profile/{scheme_path}")
        };

        let bytes = full.as_bytes();
        let len = bytes.len().min(buf.len());
        buf[..len].copy_from_slice(&bytes[..len]);
        Ok(len)
    }

    fn fevent(&mut self, id: usize, _flags: syscall::flag::EventFlags, _ctx: &CallerCtx) -> Result<syscall::flag::EventFlags> {
        match self.handles.get(id) {
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
        match self.handles.get(id) {
            Some(Handle::File(fh)) => {
                // Synthetic stat from manifest — NO filesystem I/O.
                stat.st_size = fh.size;
                stat.st_mode = if fh.executable { 0o100555 } else { 0o100444 };
                stat.st_nlink = 1;
            }
            Some(Handle::Dir(_)) => {
                stat.st_mode = 0o040555; // Directory, read+execute.
                stat.st_size = 0;
            }
            Some(Handle::Control(_)) => {
                stat.st_mode = 0o100222; // Write-only file.
                stat.st_size = 0;
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
        let (profile_name, subpath) = match self.handles.get(id) {
            Some(Handle::Dir(dh)) => (dh.profile_name.clone(), dh.subpath.clone()),
            Some(_) => return Err(Error::new(ENOTDIR)),
            None => return Err(Error::new(EBADF)),
        };

        let start = opaque_offset as usize;

        if profile_name.is_empty() {
            // Scheme root: list all profiles.
            let profiles = self.daemon.profiles.list_profiles();
            for (i, name) in profiles.iter().enumerate().skip(start) {
                if buf
                    .entry(RedoxDirEntry {
                        inode: 0,
                        next_opaque_id: (i + 1) as u64,
                        name,
                        kind: DirentKind::Directory,
                    })
                    .is_err()
                {
                    break;
                }
            }
        } else if subpath.is_empty() {
            // Profile root: list the common top-level dirs.
            // We synthesize known directory names that profiles typically have.
            let mapping = match self.daemon.profiles.get(&profile_name) {
                Some(m) => m,
                None => return Ok(buf),
            };

            // Collect all top-level entries across all packages.
            // Use manifests to avoid filesystem I/O.
            let entries = mapping.list_union_from_manifests(
                "",
                &self.daemon.manifests,
            );
            // Also add .control as a synthetic entry.
            let mut all_entries: Vec<(&str, DirentKind)> = entries
                .iter()
                .map(|e| {
                    let kind = if e.is_dir {
                        DirentKind::Directory
                    } else {
                        DirentKind::Regular
                    };
                    (e.name.as_str(), kind)
                })
                .collect();
            // We can't easily push a borrowed str from a local, so handle .control separately.

            for (i, (name, kind)) in all_entries.iter().enumerate().skip(start) {
                if buf
                    .entry(RedoxDirEntry {
                        inode: 0,
                        next_opaque_id: (i + 1) as u64,
                        name,
                        kind: *kind,
                    })
                    .is_err()
                {
                    break;
                }
            }

            // Add .control entry at the end.
            let ctrl_idx = all_entries.len();
            if start <= ctrl_idx {
                let _ = buf.entry(RedoxDirEntry {
                    inode: 0,
                    next_opaque_id: (ctrl_idx + 1) as u64,
                    name: ".control",
                    kind: DirentKind::Regular,
                });
            }
        } else {
            // Subdirectory within a profile: union listing.
            let mapping = match self.daemon.profiles.get(&profile_name) {
                Some(m) => m,
                None => return Ok(buf),
            };

            let entries = mapping.list_union_from_manifests(
                &subpath,
                &self.daemon.manifests,
            );
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
        // For control handles: process the accumulated command.
        if let Some(Handle::Control(ch)) = self.handles.close(id) {
            if !ch.buffer.is_empty() {
                let command = String::from_utf8_lossy(&ch.buffer);
                match self
                    .daemon
                    .profiles
                    .process_control(&ch.profile_name, &command)
                {
                    Ok((msg, files)) => {
                        eprintln!("profiled: {msg}");
                        // Store manifest data if provided in the command.
                        if let Some((store_path, manifest)) = files {
                            self.daemon.manifests.insert(store_path, manifest);
                        }
                    }
                    Err(e) => eprintln!("profiled: control error: {e}"),
                }
            }
        } else {
            // File/Dir handle already removed by close().
        }
    }
}

/// Run the profile scheme daemon (blocking).
pub fn run_daemon(config: ProfiledConfig) -> Result<(), Box<dyn std::error::Error>> {
    eprintln!(
        "profiled: initializing (profiles={}, store={})",
        config.profiles_dir, config.store_dir
    );

    let daemon = ProfileDaemon::new(config)?;
    let profile_count = daemon.profiles.list_profiles().len();
    eprintln!("profiled: loaded {profile_count} profiles");

    let mut handler = ProfileSchemeHandler::new(daemon);
    let mut state = SchemeState::new();

    // Register the `profile` scheme with the kernel.
    eprintln!("profiled: creating scheme socket...");
    let socket = match Socket::create() {
        Ok(s) => {
            eprintln!("profiled: socket created successfully");
            s
        }
        Err(e) => {
            eprintln!("profiled: Socket::create() failed: {e}");
            eprintln!("profiled: this requires /scheme/namespace/scheme-creation-cap");
            return Err(format!("profiled: Socket::create failed: {e}").into());
        }
    };

    eprintln!("profiled: registering scheme 'profile'...");
    match redox_scheme::scheme::register_sync_scheme(&socket, "profile", &mut handler) {
        Ok(()) => eprintln!("profiled: scheme 'profile' registered"),
        Err(e) => {
            eprintln!("profiled: register_sync_scheme failed: {e}");
            eprintln!("profiled: error code: {:?}", e);
            return Err(format!("profiled: registration failed: {e}").into());
        }
    }

    // Pre-open "/" to get a direct fd to redoxfs. Must be done BEFORE
    // setrens(0, 0). The root_fd allows the FileIoWorker to continue
    // reading files via SYS_OPENAT after the namespace is null.
    eprintln!("profiled: pre-opening /");
    let root_file = std::fs::File::open("/").map_err(|e| {
        format!("profiled: failed to open /: {e}")
    })?;
    let root_fd = {
        use std::os::unix::io::AsRawFd;
        root_file.as_raw_fd() as usize
    };
    eprintln!("profiled: root_fd={root_fd}");

    // Restart the FileIoWorker with the root_fd.
    handler.handles.io_worker = Some(
        crate::file_io_worker::FileIoWorker::spawn(Some(root_fd))
    );

    // Drop into null namespace.
    eprintln!("profiled: entering null namespace");
    libredox::call::setrens(0, 0).map_err(|e| {
        format!("profiled: setrens(0, 0) failed: {e}")
    })?;

    let _root_file = root_file;

    // Main event loop.
    eprintln!("profiled: entering event loop");
    loop {
        let req = match socket.next_request(SignalBehavior::Restart)? {
            None => {
                eprintln!("profiled: socket closed");
                break;
            }
            Some(req) => req,
        };

        match req.kind() {
            RequestKind::Call(call_req) => {

                let response = call_req.handle_sync(&mut handler, &mut state);

                if !socket.write_response(response, SignalBehavior::Restart)? {
                    eprintln!("profiled: write_response returned false");
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

    eprintln!("profiled: shutting down");
    Ok(())
}
