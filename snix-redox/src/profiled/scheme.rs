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
            handles: HandleTable::new(),
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
                    // Try to resolve through the profile mapping.
                    let mapping = self
                        .daemon
                        .profiles
                        .get(name)
                        .ok_or_else(|| Error::new(ENOENT))?;

                    let resolved = mapping.resolve_path(subpath).ok_or_else(|| {
                        // Maybe it's a directory? Check by trying to list it.
                        let entries = mapping.list_union(subpath);
                        if !entries.is_empty() {
                            // It's a directory path — return ENOTDIR to hint
                            // the caller should use O_DIRECTORY. But most callers
                            // will just see ENOENT.
                            return Error::new(ENOENT);
                        }
                        Error::new(ENOENT)
                    })?;

                    let id = self
                        .handles
                        .open_file(resolved.full_path, path.to_string())
                        .map_err(|e| {
                            eprintln!("profiled: open file: {e}");
                            Error::new(EIO)
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

    fn fstat(&mut self, id: usize, stat: &mut Stat, _ctx: &CallerCtx) -> Result<()> {
        match self.handles.get(id) {
            Some(Handle::File(fh)) => {
                let meta = fh.file.metadata().map_err(|_| Error::new(EIO))?;
                stat.st_size = meta.len();
                stat.st_mode = 0o100444; // Regular file, read-only.

                #[cfg(unix)]
                {
                    use std::os::unix::fs::MetadataExt;
                    stat.st_mode = meta.mode() as u16;
                    stat.st_uid = meta.uid();
                    stat.st_gid = meta.gid();
                    stat.st_ino = meta.ino();
                    stat.st_nlink = meta.nlink() as u32;
                }
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
            let entries = mapping.list_union("");
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

            let entries = mapping.list_union(&subpath);
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
                    Ok(msg) => eprintln!("profiled: {msg}"),
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
    let socket = Socket::create()?;

    eprintln!("profiled: registering scheme 'profile'...");
    redox_scheme::scheme::register_sync_scheme(&socket, "profile", &mut handler)?;
    eprintln!("profiled: scheme 'profile' registered");

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

    eprintln!("profiled: shutting down");
    Ok(())
}
