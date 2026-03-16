//! Redox scheme implementation for virtio-fs.
//!
//! Maps Redox filesystem operations (SchemeSync trait) to FUSE operations
//! via the FuseSession. This is how userspace programs on Redox access
//! the shared host directory.
//!
//! Path resolution:
//!   Redox open("/scheme/shared/foo/bar") → FUSE LOOKUP(root, "foo") → LOOKUP(foo, "bar")
//!
//! Handle tracking:
//!   Each open file/directory gets a Redox handle ID mapped to:
//!   - FUSE node ID (for getattr, read, etc.)
//!   - FUSE file handle (from FUSE_OPEN/OPENDIR)
//!   - Cached attributes
//!   - Whether it's a directory

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicUsize, Ordering};

use redox_scheme::scheme::SchemeSync;
use redox_scheme::{CallerCtx, OpenResult};
use syscall::data::{Stat, StatVfs};
use syscall::dirent::{DirEntry as RedoxDirEntry, DirentBuf, DirentKind};
use syscall::error::{
    Error, Result, EACCES, EBADF, EBUSY, EEXIST, EINVAL, EIO, EISDIR, ELOOP, ENAMETOOLONG,
    ENOENT, ENOMEM, ENOSPC, ENOSYS, ENOTDIR, ENOTEMPTY, EPERM, ERANGE,
};
use syscall::flag::{
    EventFlags, O_ACCMODE, O_CREAT, O_DIRECTORY, O_EXCL, O_RDONLY, O_STAT, O_TRUNC, O_WRONLY,
};
use syscall::schemev2::NewFdFlags;

use crate::fuse::{S_IFDIR, S_IFLNK, S_IFMT};
use crate::session::{DirEntry, FuseSession};
use crate::transport::FuseTransportError;

// Linux open flag values (for FUSE translation)
const LINUX_O_WRONLY: u32 = 1;
const LINUX_O_RDWR: u32 = 2;
const LINUX_O_CREAT: u32 = 0o100;
const LINUX_O_EXCL: u32 = 0o200;
const LINUX_O_TRUNC: u32 = 0o1000;
const LINUX_O_APPEND: u32 = 0o2000;

/// Convert Redox open flags to FUSE/Linux open flags.
///
/// Redox uses different flag values than Linux:
///   Redox O_RDONLY = 0x0001_0000   Linux O_RDONLY = 0
///   Redox O_WRONLY = 0x0002_0000   Linux O_WRONLY = 1
///   Redox O_RDWR   = 0x0003_0000   Linux O_RDWR   = 2
///   Redox O_CREAT  = 0x0200_0000   Linux O_CREAT  = 0o100
///   Redox O_EXCL   = 0x0800_0000   Linux O_EXCL   = 0o200
///   Redox O_TRUNC  = 0x0400_0000   Linux O_TRUNC  = 0o1000
///
/// FUSE passes these flags to the host virtiofsd which calls open() with
/// Linux flags. Passing raw Redox flags causes EINVAL/ENOENT on the host.
fn redox_to_fuse_flags(redox_flags: usize) -> u32 {
    let mut fuse = 0u32;

    // Access mode
    let mode = redox_flags & O_ACCMODE;
    if mode == O_WRONLY {
        fuse |= LINUX_O_WRONLY;
    } else if mode == (O_RDONLY | O_WRONLY) {
        fuse |= LINUX_O_RDWR;
    }
    // O_RDONLY = 0 in Linux, no bit to set

    // Creation / truncation flags
    if redox_flags & O_CREAT != 0 {
        fuse |= LINUX_O_CREAT;
    }
    if redox_flags & O_EXCL != 0 {
        fuse |= LINUX_O_EXCL;
    }
    if redox_flags & O_TRUNC != 0 {
        fuse |= LINUX_O_TRUNC;
    }

    fuse
}

/// Map a FUSE/Linux errno value (positive) to the corresponding Redox error.
///
/// FUSE error codes in the protocol are negative Linux errno values. The caller
/// should pass the absolute value. Unrecognized codes fall back to EIO.
fn fuse_error_to_redox(fuse_errno: i32) -> Error {
    match fuse_errno {
        1 => Error::new(EPERM),
        2 => Error::new(ENOENT),
        12 => Error::new(ENOMEM),
        13 => Error::new(EACCES),
        16 => Error::new(EBUSY),
        17 => Error::new(EEXIST),
        20 => Error::new(ENOTDIR),
        21 => Error::new(EISDIR),
        22 => Error::new(EINVAL),
        28 => Error::new(ENOSPC),
        34 => Error::new(ERANGE),
        36 => Error::new(ENAMETOOLONG),
        38 => Error::new(ENOSYS),
        39 => Error::new(ENOTEMPTY),
        40 => Error::new(ELOOP),
        _ => Error::new(EIO),
    }
}

/// Convert a `FuseTransportError` to a Redox `Error`, logging a warning.
///
/// For FUSE protocol errors, extracts the negative errno and maps it via
/// `fuse_error_to_redox`. All other transport errors (DMA, short response,
/// unexpected size) become EIO. Every conversion is logged at warn level.
fn fuse_err(e: FuseTransportError) -> Error {
    let err = match &e {
        FuseTransportError::FuseError(neg_errno) => fuse_error_to_redox(-neg_errno),
        _ => Error::new(EIO),
    };
    log::warn!("FUSE transport error: {} -> {:?}", e, err);
    err
}

/// An open file or directory handle.
struct Handle {
    /// FUSE node ID.
    nodeid: u64,
    /// FUSE file handle (from OPEN/OPENDIR).
    fh: u64,
    /// Is this a directory?
    is_dir: bool,
    /// Whether this handle was opened with write access.
    writable: bool,
    /// Cached path (for fpath).
    path: String,
    /// Cached file size.
    size: u64,
    /// Cached mode (POSIX).
    mode: u32,
    /// Cached directory listing (lazily populated).
    dir_entries: Option<Vec<DirEntry>>,
}

pub struct VirtioFsScheme<'a> {
    session: FuseSession<'a>,
    scheme_name: String,
    next_id: AtomicUsize,
    handles: BTreeMap<usize, Handle>,
}

impl<'a> VirtioFsScheme<'a> {
    pub fn new(session: FuseSession<'a>, scheme_name: String) -> Self {
        Self {
            session,
            scheme_name,
            next_id: AtomicUsize::new(1),
            handles: BTreeMap::new(),
        }
    }

    /// Resolve a path relative to the FUSE root by walking LOOKUP.
    ///
    /// Follows symlinks transparently: after each LOOKUP, if the returned
    /// node has `S_IFLNK` mode, calls FUSE_READLINK and continues resolution
    /// from the symlink target. A hop counter prevents infinite loops.
    fn resolve_path(&mut self, path: &str) -> Result<(u64, crate::fuse::FuseAttr)> {
        self.resolve_path_hops(path, 40)
    }

    fn resolve_path_hops(
        &mut self,
        path: &str,
        max_hops: u32,
    ) -> Result<(u64, crate::fuse::FuseAttr)> {
        let path = path.trim_matches('/');

        if path.is_empty() {
            // Root node
            let attr_out = self
                .session
                .getattr(1) // FUSE root nodeid is always 1
                .map_err(fuse_err)?;
            return Ok((1, attr_out.attr));
        }

        let mut current_nodeid: u64 = 1; // FUSE root
        let mut hops_remaining = max_hops;

        // Collect components so we can splice in symlink target components
        let mut components: Vec<String> = path.split('/').map(|s| s.to_string()).collect();
        let mut i = 0;

        while i < components.len() {
            let component = &components[i];
            if component.is_empty() {
                i += 1;
                continue;
            }

            let entry = self
                .session
                .lookup(current_nodeid, component)
                .map_err(fuse_err)?;

            // Check if this node is a symlink
            if (entry.attr.mode & S_IFMT) == S_IFLNK {
                if hops_remaining == 0 {
                    return Err(Error::new(ELOOP));
                }
                hops_remaining -= 1;

                let target = self
                    .session
                    .readlink(entry.nodeid)
                    .map_err(fuse_err)?;

                // Remove the current component and splice in the target's components
                components.remove(i);

                let target_components: Vec<String> =
                    target.split('/').map(|s| s.to_string()).collect();

                if target.starts_with('/') {
                    // Absolute symlink: restart from FUSE root
                    current_nodeid = 1;
                    // Replace everything up to this point with the target
                    components.splice(0..i, target_components);
                    i = 0;
                } else {
                    // Relative symlink: continue from current parent
                    for (j, tc) in target_components.into_iter().enumerate() {
                        components.insert(i + j, tc);
                    }
                    // Don't advance i — re-resolve from the first target component
                }

                continue;
            }

            current_nodeid = entry.nodeid;
            i += 1;
        }

        // Get attributes of the final node
        let attr_out = self
            .session
            .getattr(current_nodeid)
            .map_err(fuse_err)?;

        Ok((current_nodeid, attr_out.attr))
    }
}

impl<'a> SchemeSync for VirtioFsScheme<'a> {
    fn scheme_root(&mut self) -> Result<usize> {
        // Open the root directory
        let attr_out = self
            .session
            .getattr(1)
            .map_err(fuse_err)?;

        let dir_handle = self
            .session
            .opendir(1)
            .map_err(fuse_err)?;

        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        self.handles.insert(
            id,
            Handle {
                nodeid: 1,
                fh: dir_handle.fh,
                is_dir: true,
                writable: false,
                path: String::new(),
                size: attr_out.attr.size,
                mode: attr_out.attr.mode,
                dir_entries: None,
            },
        );

        Ok(id)
    }

    fn openat(
        &mut self,
        dirfd: usize,
        path: &str,
        flags: usize,
        _fcntl_flags: u32,
        _ctx: &CallerCtx,
    ) -> Result<OpenResult> {
        log::debug!("openat: dirfd={}, path={:?}, flags={:#x}", dirfd, path, flags);
        let path = path.trim_matches('/');

        // Resolve the starting directory
        let base_path = if let Some(handle) = self.handles.get(&dirfd) {
            if path.starts_with('/') {
                String::new() // absolute path, ignore dirfd
            } else {
                handle.path.clone()
            }
        } else {
            String::new()
        };

        let full_path = if base_path.is_empty() {
            path.to_string()
        } else if path.is_empty() {
            base_path
        } else {
            format!("{}/{}", base_path, path)
        };

        let access_mode = flags & O_ACCMODE;
        let writable = access_mode == O_WRONLY || access_mode == (O_RDONLY | O_WRONLY);

        // O_CREAT: create-if-not-exists
        if flags & O_CREAT != 0 {
            // Resolve parent directory and filename
            let (parent_path, filename) = match full_path.rfind('/') {
                Some(pos) => (&full_path[..pos], &full_path[pos + 1..]),
                None => ("", full_path.as_str()),
            };

            let (parent_nodeid, _) = if parent_path.is_empty() {
                let attr_out = self
                    .session
                    .getattr(1)
                    .map_err(fuse_err)?;
                (1u64, attr_out.attr)
            } else {
                self.resolve_path(parent_path)?
            };

            // Check if target already exists
            let existing = self.resolve_path(&full_path);

            if let Ok((nodeid, attr)) = existing {
                if flags & O_EXCL != 0 {
                    return Err(Error::new(EEXIST));
                }

                // File exists — open it (with O_TRUNC if requested)
                let is_dir = (attr.mode & S_IFMT) == S_IFDIR;
                if is_dir {
                    let dir_handle = self
                        .session
                        .opendir(nodeid)
                        .map_err(fuse_err)?;

                    let id = self.next_id.fetch_add(1, Ordering::Relaxed);
                    self.handles.insert(
                        id,
                        Handle {
                            nodeid,
                            fh: dir_handle.fh,
                            is_dir: true,
                            writable: false,
                            path: full_path,
                            size: attr.size,
                            mode: attr.mode,
                            dir_entries: None,
                        },
                    );
                    return Ok(OpenResult::ThisScheme {
                        number: id,
                        flags: NewFdFlags::POSITIONED,
                    });
                }

                let fuse_flags = redox_to_fuse_flags(flags);
                let file_handle = self
                    .session
                    .open(nodeid, fuse_flags)
                    .map_err(fuse_err)?;

                let id = self.next_id.fetch_add(1, Ordering::Relaxed);
                self.handles.insert(
                    id,
                    Handle {
                        nodeid,
                        fh: file_handle.fh,
                        is_dir: false,
                        writable,
                        path: full_path,
                        size: attr.size,
                        mode: attr.mode,
                        dir_entries: None,
                    },
                );
                return Ok(OpenResult::ThisScheme {
                    number: id,
                    flags: NewFdFlags::POSITIONED,
                });
            }

            // Target doesn't exist — create it
            if flags & O_DIRECTORY != 0 {
                // O_CREAT | O_DIRECTORY: create a directory (mkdir)
                let entry = self
                    .session
                    .mkdir(parent_nodeid, filename, 0o755)
                    .map_err(fuse_err)?;

                let dir_handle = self
                    .session
                    .opendir(entry.nodeid)
                    .map_err(fuse_err)?;

                let id = self.next_id.fetch_add(1, Ordering::Relaxed);
                self.handles.insert(
                    id,
                    Handle {
                        nodeid: entry.nodeid,
                        fh: dir_handle.fh,
                        is_dir: true,
                        writable: false,
                        path: full_path,
                        size: entry.attr.size,
                        mode: entry.attr.mode,
                        dir_entries: None,
                    },
                );

                return Ok(OpenResult::ThisScheme {
                    number: id,
                    flags: NewFdFlags::POSITIONED,
                });
            }

            // Regular file creation: FUSE_CREATE (atomic create + open)
            let fuse_flags = redox_to_fuse_flags(flags);
            let (entry, open) = self
                .session
                .create(parent_nodeid, filename, fuse_flags, 0o644)
                .map_err(fuse_err)?;

            let id = self.next_id.fetch_add(1, Ordering::Relaxed);
            self.handles.insert(
                id,
                Handle {
                    nodeid: entry.nodeid,
                    fh: open.fh,
                    is_dir: false,
                    writable: true,
                    path: full_path,
                    size: entry.attr.size,
                    mode: entry.attr.mode,
                    dir_entries: None,
                },
            );

            return Ok(OpenResult::ThisScheme {
                number: id,
                flags: NewFdFlags::POSITIONED,
            });
        }

        // Regular open (no O_CREAT)
        let (nodeid, attr) = self.resolve_path(&full_path)?;
        let is_dir = (attr.mode & S_IFMT) == S_IFDIR;

        // Stat-only open doesn't need a FUSE file handle
        if flags & O_STAT == O_STAT {
            let id = self.next_id.fetch_add(1, Ordering::Relaxed);
            self.handles.insert(
                id,
                Handle {
                    nodeid,
                    fh: 0,
                    is_dir,
                    writable: false,
                    path: full_path,
                    size: attr.size,
                    mode: attr.mode,
                    dir_entries: None,
                },
            );

            return Ok(OpenResult::ThisScheme {
                number: id,
                flags: NewFdFlags::POSITIONED,
            });
        }

        if is_dir {
            if flags & O_DIRECTORY != O_DIRECTORY && (flags & O_ACCMODE) != O_RDONLY {
                return Err(Error::new(EISDIR));
            }

            let dir_handle = self
                .session
                .opendir(nodeid)
                .map_err(fuse_err)?;

            let id = self.next_id.fetch_add(1, Ordering::Relaxed);
            self.handles.insert(
                id,
                Handle {
                    nodeid,
                    fh: dir_handle.fh,
                    is_dir: true,
                    writable: false,
                    path: full_path,
                    size: attr.size,
                    mode: attr.mode,
                    dir_entries: None,
                },
            );

            Ok(OpenResult::ThisScheme {
                number: id,
                flags: NewFdFlags::POSITIONED,
            })
        } else {
            if flags & O_DIRECTORY == O_DIRECTORY {
                return Err(Error::new(ENOTDIR));
            }

            let fuse_flags = redox_to_fuse_flags(flags);
            let file_handle = self
                .session
                .open(nodeid, fuse_flags)
                .map_err(fuse_err)?;

            let id = self.next_id.fetch_add(1, Ordering::Relaxed);
            self.handles.insert(
                id,
                Handle {
                    nodeid,
                    fh: file_handle.fh,
                    is_dir: false,
                    writable,
                    path: full_path,
                    size: attr.size,
                    mode: attr.mode,
                    dir_entries: None,
                },
            );

            Ok(OpenResult::ThisScheme {
                number: id,
                flags: NewFdFlags::POSITIONED,
            })
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
        log::debug!("read: handle={}, offset={}, size={}", id, offset, buf.len());
        let handle = self.handles.get(&id).ok_or(Error::new(EBADF))?;

        if handle.is_dir {
            return Err(Error::new(EISDIR));
        }

        let nodeid = handle.nodeid;
        let fh = handle.fh;

        let data = self
            .session
            .read(nodeid, fh, offset, buf.len() as u32)
            .map_err(fuse_err)?;

        let copy_len = data.len().min(buf.len());
        buf[..copy_len].copy_from_slice(&data[..copy_len]);
        Ok(copy_len)
    }

    fn write(
        &mut self,
        id: usize,
        buf: &[u8],
        offset: u64,
        _fcntl_flags: u32,
        _ctx: &CallerCtx,
    ) -> Result<usize> {
        log::debug!("write: handle={}, offset={}, size={}", id, offset, buf.len());
        let handle = self.handles.get(&id).ok_or(Error::new(EBADF))?;

        if handle.is_dir {
            return Err(Error::new(EISDIR));
        }
        if !handle.writable {
            return Err(Error::new(EBADF));
        }

        let nodeid = handle.nodeid;
        let fh = handle.fh;

        let written = self
            .session
            .write(nodeid, fh, offset, buf)
            .map_err(fuse_err)?;

        // Update cached size if write extends beyond current end
        if let Some(h) = self.handles.get_mut(&id) {
            let new_end = offset + written as u64;
            if new_end > h.size {
                h.size = new_end;
            }
        }

        Ok(written as usize)
    }

    fn ftruncate(&mut self, id: usize, len: u64, _ctx: &CallerCtx) -> Result<()> {
        log::debug!("ftruncate: handle={}, len={}", id, len);
        let handle = self.handles.get(&id).ok_or(Error::new(EBADF))?;

        if !handle.writable {
            return Err(Error::new(EBADF));
        }

        let nodeid = handle.nodeid;
        let fh = handle.fh;

        let attr_out = self
            .session
            .truncate(nodeid, fh, len)
            .map_err(fuse_err)?;

        // Update cached size
        if let Some(h) = self.handles.get_mut(&id) {
            h.size = attr_out.attr.size;
        }

        Ok(())
    }

    fn fsize(&mut self, id: usize, _ctx: &CallerCtx) -> Result<u64> {
        log::debug!("fsize: handle={}", id);
        let handle = self.handles.get(&id).ok_or(Error::new(EBADF))?;
        let nodeid = handle.nodeid;

        // Refresh attributes
        let attr_out = self
            .session
            .getattr(nodeid)
            .map_err(fuse_err)?;

        // Update cached size
        if let Some(h) = self.handles.get_mut(&id) {
            h.size = attr_out.attr.size;
        }

        Ok(attr_out.attr.size)
    }

    fn fpath(&mut self, id: usize, buf: &mut [u8], _ctx: &CallerCtx) -> Result<usize> {
        log::debug!("fpath: handle={}", id);
        let handle = self.handles.get(&id).ok_or(Error::new(EBADF))?;

        let scheme_path = format!("/scheme/{}", self.scheme_name);
        let full = if handle.path.is_empty() {
            scheme_path
        } else {
            format!("{}/{}", scheme_path, handle.path)
        };

        let bytes = full.as_bytes();
        let len = bytes.len().min(buf.len());
        buf[..len].copy_from_slice(&bytes[..len]);
        Ok(len)
    }

    fn fstat(&mut self, id: usize, stat: &mut Stat, _ctx: &CallerCtx) -> Result<()> {
        log::debug!("fstat: handle={}", id);
        let handle = self.handles.get(&id).ok_or(Error::new(EBADF))?;
        let nodeid = handle.nodeid;

        let attr_out = self
            .session
            .getattr(nodeid)
            .map_err(fuse_err)?;

        let attr = &attr_out.attr;

        // Redox Stat uses plain u64 for times, plus separate nsec u32 fields
        stat.st_mode = attr.mode as u16;
        stat.st_size = attr.size;
        stat.st_blksize = attr.blksize;
        stat.st_blocks = attr.blocks;
        stat.st_nlink = attr.nlink;
        stat.st_uid = attr.uid;
        stat.st_gid = attr.gid;
        stat.st_ino = attr.ino;
        stat.st_atime = attr.atime;
        stat.st_atime_nsec = attr.atimensec;
        stat.st_mtime = attr.mtime;
        stat.st_mtime_nsec = attr.mtimensec;
        stat.st_ctime = attr.ctime;
        stat.st_ctime_nsec = attr.ctimensec;

        Ok(())
    }

    fn fstatvfs(&mut self, id: usize, stat: &mut StatVfs, _ctx: &CallerCtx) -> Result<()> {
        log::debug!("fstatvfs: handle={}", id);
        let _handle = self.handles.get(&id).ok_or(Error::new(EBADF))?;

        let fsstat = self
            .session
            .statfs()
            .map_err(fuse_err)?;

        stat.f_bsize = fsstat.st.bsize;
        stat.f_blocks = fsstat.st.blocks;
        stat.f_bfree = fsstat.st.bfree;
        stat.f_bavail = fsstat.st.bavail;

        Ok(())
    }

    fn getdents<'buf>(
        &mut self,
        id: usize,
        mut buf: DirentBuf<&'buf mut [u8]>,
        opaque_offset: u64,
    ) -> Result<DirentBuf<&'buf mut [u8]>> {
        log::debug!("getdents: handle={}, opaque_offset={}", id, opaque_offset);
        let handle = self.handles.get_mut(&id).ok_or(Error::new(EBADF))?;

        if !handle.is_dir {
            return Err(Error::new(ENOTDIR));
        }

        let nodeid = handle.nodeid;
        let fh = handle.fh;

        // Fetch directory entries if not cached or if offset is 0 (restart)
        if handle.dir_entries.is_none() || opaque_offset == 0 {
            let entries = self
                .session
                .readdir(nodeid, fh, 0, 32768)
                .map_err(fuse_err)?;
            handle.dir_entries = Some(entries);
        }

        if let Some(ref entries) = handle.dir_entries {
            let start = opaque_offset as usize;

            for (i, entry) in entries.iter().enumerate().skip(start) {
                let kind = match entry.typ {
                    4 => DirentKind::Directory,   // DT_DIR
                    8 => DirentKind::Regular,     // DT_REG
                    10 => DirentKind::Symlink,    // DT_LNK
                    _ => DirentKind::Regular,
                };

                // DirentBuf.entry() takes a DirEntry struct
                if buf
                    .entry(RedoxDirEntry {
                        inode: entry.ino,
                        next_opaque_id: (i + 1) as u64,
                        name: &entry.name,
                        kind,
                    })
                    .is_err()
                {
                    break; // Buffer full
                }
            }
        }

        Ok(buf)
    }

    fn unlinkat(
        &mut self,
        fd: usize,
        path: &str,
        _flags: usize,
        _ctx: &CallerCtx,
    ) -> Result<()> {
        log::debug!("unlinkat: fd={}, path={:?}", fd, path);
        let path = path.trim_matches('/');

        // Resolve base directory from fd handle
        let base_path = if let Some(handle) = self.handles.get(&fd) {
            handle.path.clone()
        } else {
            String::new()
        };

        let full_path = if base_path.is_empty() {
            path.to_string()
        } else if path.is_empty() {
            return Err(Error::new(ENOENT));
        } else {
            format!("{}/{}", base_path, path)
        };

        // Resolve parent + filename
        let (parent_path, filename) = match full_path.rfind('/') {
            Some(pos) => (&full_path[..pos], &full_path[pos + 1..]),
            None => ("", full_path.as_str()),
        };

        let (parent_nodeid, _) = if parent_path.is_empty() {
            let attr_out = self
                .session
                .getattr(1)
                .map_err(fuse_err)?;
            (1u64, attr_out.attr)
        } else {
            self.resolve_path(parent_path)?
        };

        // Check if target is a directory or file
        let (_, attr) = self.resolve_path(&full_path)?;
        let is_dir = (attr.mode & S_IFMT) == S_IFDIR;

        if is_dir {
            self.session
                .rmdir(parent_nodeid, filename)
                .map_err(fuse_err)?;
        } else {
            self.session
                .unlink(parent_nodeid, filename)
                .map_err(fuse_err)?;
        }

        Ok(())
    }

    fn fevent(&mut self, id: usize, _flags: EventFlags, _ctx: &CallerCtx) -> Result<EventFlags> {
        if let Some(handle) = self.handles.get(&id) {
            let mut events = EventFlags::EVENT_READ;
            if handle.writable {
                events |= EventFlags::EVENT_WRITE;
            }
            Ok(events)
        } else {
            Err(Error::new(EBADF))
        }
    }

    fn on_close(&mut self, id: usize) {
        log::debug!("on_close: handle={}", id);
        if let Some(handle) = self.handles.remove(&id) {
            log::debug!(
                "on_close: handle={}, nodeid={}, is_dir={}, writable={}",
                id, handle.nodeid, handle.is_dir, handle.writable
            );
            if handle.fh != 0 {
                // Flush writable file handles before release to ensure
                // the host pushes dirty pages to stable storage.
                if handle.writable && !handle.is_dir {
                    if let Err(e) = self.session.flush(handle.nodeid, handle.fh) {
                        log::warn!(
                            "on_close: flush failed for handle={}, nodeid={}: {}",
                            id, handle.nodeid, e
                        );
                    }
                }

                if handle.is_dir {
                    let _ = self.session.releasedir(handle.nodeid, handle.fh);
                } else {
                    let _ = self.session.release(handle.nodeid, handle.fh);
                }
            }
        }
    }
}
