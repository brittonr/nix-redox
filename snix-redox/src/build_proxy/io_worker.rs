//! Background real-filesystem I/O worker for the build proxy.
//!
//! The build proxy's event loop handles a userspace `file:` scheme request.
//! If that same thread tries to call into another userspace scheme (redoxfs)
//! via `SYS_OPENAT(root_fd, ...)`, the request can deadlock because the
//! scheme handler thread is now blocked inside nested scheme I/O.
//!
//! Fix: keep all real filesystem syscalls off the scheme event loop thread.
//! The handler sends requests to this worker over a channel, then waits for
//! the reply. The worker thread owns the pre-opened `root_fd` and any
//! pre-opened device files, so it can safely perform the actual `openat`,
//! `read`, `write`, `fstat`, `fchmod`, `ftruncate`, and `getdents` calls.

use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::unix::io::{AsRawFd, FromRawFd};
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::thread;

use syscall::data::{Map, Stat};
use syscall::dirent::DirentKind;
use syscall::error::{Error, Result, EBADF, EIO};
use syscall::flag::{MapFlags, O_CREAT, O_DIRECTORY, O_RDONLY, O_RDWR, O_TRUNC};

pub struct OpenPathResult {
    pub stat: Stat,
    pub resolved_path: PathBuf,
}

pub struct WriteResult {
    pub bytes_written: usize,
    pub end_offset: u64,
}

pub struct MmapResult {
    pub token: u64,
    pub base_addr: usize,
}

struct ActiveMap {
    base_addr: usize,
    len: usize,
    backing_fd: usize,
}

enum IoRequest {
    OpenPath {
        path: PathBuf,
        flags: usize,
        response: mpsc::Sender<Result<OpenPathResult>>,
    },
    EnsureDirTree {
        path: PathBuf,
        response: mpsc::Sender<Result<()>>,
    },
    ReadAt {
        path: PathBuf,
        offset: u64,
        len: usize,
        response: mpsc::Sender<Result<Vec<u8>>>,
    },
    WriteAt {
        path: PathBuf,
        offset: u64,
        append: bool,
        data: Vec<u8>,
        response: mpsc::Sender<Result<WriteResult>>,
    },
    StatPath {
        path: PathBuf,
        directory: bool,
        response: mpsc::Sender<Result<Stat>>,
    },
    ChmodPath {
        path: PathBuf,
        directory: bool,
        new_mode: u16,
        response: mpsc::Sender<Result<()>>,
    },
    TruncatePath {
        path: PathBuf,
        len: u64,
        response: mpsc::Sender<Result<()>>,
    },
    ReadDir {
        path: PathBuf,
        response: mpsc::Sender<Result<Vec<(String, DirentKind)>>>,
    },
    ResolvePath {
        path: PathBuf,
        response: mpsc::Sender<Result<PathBuf>>,
    },
    RenamePath {
        old_path: PathBuf,
        new_path: PathBuf,
        response: mpsc::Sender<Result<()>>,
    },
    MmapPath {
        path: PathBuf,
        offset: u64,
        size: usize,
        flags: MapFlags,
        response: mpsc::Sender<Result<MmapResult>>,
    },
    MunmapToken {
        token: u64,
        response: mpsc::Sender<Result<()>>,
    },
    Shutdown,
}

pub struct BuildFsIoWorker {
    sender: mpsc::Sender<IoRequest>,
    _handle: thread::JoinHandle<()>,
}

impl BuildFsIoWorker {
    pub fn spawn(
        root_file: File,
        profile_root: Option<File>,
        store_root: Option<File>,
        dev_null: Option<File>,
        dev_urandom: Option<File>,
        rustlib_dir_cache: HashMap<PathBuf, Vec<(String, DirentKind)>>,
    ) -> Self {
        let (tx, rx) = mpsc::channel::<IoRequest>();

        let handle = thread::Builder::new()
            .name("buildfs-io-worker".to_string())
            .spawn(move || {
                worker_main(
                    rx,
                    root_file,
                    profile_root,
                    store_root,
                    dev_null,
                    dev_urandom,
                    rustlib_dir_cache,
                )
            })
            .expect("buildfs io worker spawn");

        Self {
            sender: tx,
            _handle: handle,
        }
    }

    fn request<T>(&self, request: IoRequest, rx: mpsc::Receiver<Result<T>>) -> Result<T> {
        self.sender.send(request).map_err(|_| Error::new(EIO))?;
        rx.recv().map_err(|_| Error::new(EIO))?
    }

    pub fn open_path(&self, path: &Path, flags: usize) -> Result<OpenPathResult> {
        let (tx, rx) = mpsc::channel();
        self.request(
            IoRequest::OpenPath {
                path: path.to_path_buf(),
                flags,
                response: tx,
            },
            rx,
        )
    }

    pub fn ensure_dir_tree(&self, path: &Path) -> Result<()> {
        let (tx, rx) = mpsc::channel();
        self.request(
            IoRequest::EnsureDirTree {
                path: path.to_path_buf(),
                response: tx,
            },
            rx,
        )
    }

    pub fn read_at(&self, path: &Path, offset: u64, len: usize) -> Result<Vec<u8>> {
        let (tx, rx) = mpsc::channel();
        self.request(
            IoRequest::ReadAt {
                path: path.to_path_buf(),
                offset,
                len,
                response: tx,
            },
            rx,
        )
    }

    pub fn write_at(
        &self,
        path: &Path,
        offset: u64,
        append: bool,
        data: &[u8],
    ) -> Result<WriteResult> {
        let (tx, rx) = mpsc::channel();
        self.request(
            IoRequest::WriteAt {
                path: path.to_path_buf(),
                offset,
                append,
                data: data.to_vec(),
                response: tx,
            },
            rx,
        )
    }

    pub fn stat_path(&self, path: &Path, directory: bool) -> Result<Stat> {
        let (tx, rx) = mpsc::channel();
        self.request(
            IoRequest::StatPath {
                path: path.to_path_buf(),
                directory,
                response: tx,
            },
            rx,
        )
    }

    pub fn chmod_path(&self, path: &Path, directory: bool, new_mode: u16) -> Result<()> {
        let (tx, rx) = mpsc::channel();
        self.request(
            IoRequest::ChmodPath {
                path: path.to_path_buf(),
                directory,
                new_mode,
                response: tx,
            },
            rx,
        )
    }

    pub fn truncate_path(&self, path: &Path, len: u64) -> Result<()> {
        let (tx, rx) = mpsc::channel();
        self.request(
            IoRequest::TruncatePath {
                path: path.to_path_buf(),
                len,
                response: tx,
            },
            rx,
        )
    }

    pub fn read_dir(&self, path: &Path) -> Result<Vec<(String, DirentKind)>> {
        let (tx, rx) = mpsc::channel();
        self.request(
            IoRequest::ReadDir {
                path: path.to_path_buf(),
                response: tx,
            },
            rx,
        )
    }

    pub fn resolve_path(&self, path: &Path) -> Result<PathBuf> {
        let (tx, rx) = mpsc::channel();
        self.request(
            IoRequest::ResolvePath {
                path: path.to_path_buf(),
                response: tx,
            },
            rx,
        )
    }

    pub fn rename_path(&self, old_path: &Path, new_path: &Path) -> Result<()> {
        let (tx, rx) = mpsc::channel();
        self.request(
            IoRequest::RenamePath {
                old_path: old_path.to_path_buf(),
                new_path: new_path.to_path_buf(),
                response: tx,
            },
            rx,
        )
    }

    pub fn mmap_path(
        &self,
        path: &Path,
        offset: u64,
        size: usize,
        flags: MapFlags,
    ) -> Result<MmapResult> {
        let (tx, rx) = mpsc::channel();
        self.request(
            IoRequest::MmapPath {
                path: path.to_path_buf(),
                offset,
                size,
                flags,
                response: tx,
            },
            rx,
        )
    }

    pub fn munmap_token(&self, token: u64) -> Result<()> {
        let (tx, rx) = mpsc::channel();
        self.request(
            IoRequest::MunmapToken {
                token,
                response: tx,
            },
            rx,
        )
    }
}

impl Drop for BuildFsIoWorker {
    fn drop(&mut self) {
        let _ = self.sender.send(IoRequest::Shutdown);
    }
}

fn worker_main(
    rx: mpsc::Receiver<IoRequest>,
    root_file: File,
    profile_root: Option<File>,
    store_root: Option<File>,
    dev_null: Option<File>,
    dev_urandom: Option<File>,
    rustlib_dir_cache: HashMap<PathBuf, Vec<(String, DirentKind)>>,
) {
    let root_fd = root_file.as_raw_fd() as usize;
    let profile_root_fd = profile_root.as_ref().map(|f| f.as_raw_fd() as usize);
    let store_root_fd = store_root.as_ref().map(|f| f.as_raw_fd() as usize);
    let dev_null_fd = dev_null.as_ref().map(|f| f.as_raw_fd() as usize);
    let dev_urandom_fd = dev_urandom.as_ref().map(|f| f.as_raw_fd() as usize);
    let mut next_map_token = 1u64;
    let mut active_maps: HashMap<u64, ActiveMap> = HashMap::new();

    while let Ok(req) = rx.recv() {
        match req {
            IoRequest::OpenPath {
                path,
                flags,
                response,
            } => {
                let _ = response.send(worker_open_path(
                    root_fd,
                    profile_root_fd,
                    store_root_fd,
                    dev_null_fd,
                    dev_urandom_fd,
                    &path,
                    flags,
                ));
            }
            IoRequest::EnsureDirTree { path, response } => {
                let _ = response.send(worker_ensure_dir_tree(root_fd, &path));
            }
            IoRequest::ReadAt {
                path,
                offset,
                len,
                response,
            } => {
                let _ = response.send(worker_read_at(
                    root_fd,
                    profile_root_fd,
                    store_root_fd,
                    dev_null_fd,
                    dev_urandom_fd,
                    &path,
                    offset,
                    len,
                ));
            }
            IoRequest::WriteAt {
                path,
                offset,
                append,
                data,
                response,
            } => {
                let _ = response.send(worker_write_at(
                    root_fd,
                    profile_root_fd,
                    store_root_fd,
                    dev_null_fd,
                    dev_urandom_fd,
                    &path,
                    offset,
                    append,
                    &data,
                ));
            }
            IoRequest::StatPath {
                path,
                directory,
                response,
            } => {
                let _ = response.send(worker_stat_path(
                    root_fd,
                    profile_root_fd,
                    store_root_fd,
                    dev_null_fd,
                    dev_urandom_fd,
                    &path,
                    directory,
                ));
            }
            IoRequest::ChmodPath {
                path,
                directory,
                new_mode,
                response,
            } => {
                let _ = response.send(worker_chmod_path(
                    root_fd,
                    profile_root_fd,
                    store_root_fd,
                    dev_null_fd,
                    dev_urandom_fd,
                    &path,
                    directory,
                    new_mode,
                ));
            }
            IoRequest::TruncatePath {
                path,
                len,
                response,
            } => {
                let _ = response.send(worker_truncate_path(
                    root_fd,
                    profile_root_fd,
                    store_root_fd,
                    dev_null_fd,
                    dev_urandom_fd,
                    &path,
                    len,
                ));
            }
            IoRequest::ReadDir { path, response } => {
                let _ = response.send(worker_read_dir(
                    root_fd,
                    profile_root_fd,
                    store_root_fd,
                    dev_null_fd,
                    dev_urandom_fd,
                    &rustlib_dir_cache,
                    &path,
                ));
            }
            IoRequest::ResolvePath { path, response } => {
                let _ = response.send(worker_resolve_path(
                    root_fd,
                    profile_root_fd,
                    store_root_fd,
                    dev_null_fd,
                    dev_urandom_fd,
                    &path,
                ));
            }
            IoRequest::RenamePath {
                old_path,
                new_path,
                response,
            } => {
                let _ = response.send(worker_rename_path(
                    root_fd,
                    profile_root_fd,
                    store_root_fd,
                    dev_null_fd,
                    dev_urandom_fd,
                    &old_path,
                    &new_path,
                ));
            }
            IoRequest::MmapPath {
                path,
                offset,
                size,
                flags,
                response,
            } => {
                let _ = response.send(worker_mmap_path(
                    root_fd,
                    profile_root_fd,
                    store_root_fd,
                    dev_null_fd,
                    dev_urandom_fd,
                    &path,
                    offset,
                    size,
                    flags,
                    &mut next_map_token,
                    &mut active_maps,
                ));
            }
            IoRequest::MunmapToken { token, response } => {
                let _ = response.send(worker_munmap_token(token, &mut active_maps));
            }
            IoRequest::Shutdown => break,
        }
    }

    for (_, active_map) in active_maps.drain() {
        let _ = unsafe { syscall::funmap(active_map.base_addr, active_map.len) };
        raw_close(active_map.backing_fd);
    }

    drop(root_file);
    drop(profile_root);
    drop(store_root);
    drop(dev_null);
    drop(dev_urandom);
}

fn worker_open_path(
    root_fd: usize,
    profile_root_fd: Option<usize>,
    store_root_fd: Option<usize>,
    dev_null_fd: Option<usize>,
    dev_urandom_fd: Option<usize>,
    path: &Path,
    flags: usize,
) -> Result<OpenPathResult> {
    let fd = open_fd(
        root_fd,
        profile_root_fd,
        store_root_fd,
        dev_null_fd,
        dev_urandom_fd,
        path,
        flags,
    )?;
    let stat = raw_fstat(fd)?;
    let raw_path = raw_fpath(fd);
    let clean = path.to_string_lossy();
    let clean = clean.trim_start_matches('/');
    let resolved_path = match clean {
        "dev/null" | "dev/zero" | "dev/urandom" | "dev/random" => path.to_path_buf(),
        "nix/system/profile" | "nix/store" => path.to_path_buf(),
        _ if clean.starts_with("nix/system/profile/") || clean.starts_with("nix/store/") => {
            path.to_path_buf()
        }
        _ => raw_path.clone().unwrap_or_else(|| path.to_path_buf()),
    };
    if clean == "dev/null" || clean == "dev/urandom" || clean == "dev/random" {
        eprintln!(
            "buildfs-io: open_path {:?} flags={:#x} raw_fpath={:?} resolved={:?}",
            path, flags, raw_path, resolved_path
        );
    }
    raw_close(fd);
    Ok(OpenPathResult {
        stat,
        resolved_path,
    })
}

fn worker_ensure_dir_tree(root_fd: usize, path: &Path) -> Result<()> {
    mkdir_p_via_root_fd(root_fd, path);
    Ok(())
}

fn worker_read_at(
    root_fd: usize,
    profile_root_fd: Option<usize>,
    store_root_fd: Option<usize>,
    dev_null_fd: Option<usize>,
    dev_urandom_fd: Option<usize>,
    path: &Path,
    offset: u64,
    len: usize,
) -> Result<Vec<u8>> {
    let clean = path.to_string_lossy();
    let clean = clean.trim_start_matches('/');
    if clean == "dev/null" {
        eprintln!(
            "buildfs-io: read_at dev/null offset={} len={} -> eof",
            offset, len
        );
        return Ok(Vec::new());
    }
    if clean == "dev/zero" {
        return Ok(vec![0u8; len]);
    }

    let fd = open_fd(
        root_fd,
        profile_root_fd,
        store_root_fd,
        dev_null_fd,
        dev_urandom_fd,
        path,
        O_RDONLY,
    )?;
    let mut file = unsafe { File::from_raw_fd(fd as i32) };
    file.seek(SeekFrom::Start(offset))
        .map_err(|_| Error::new(EIO))?;
    let mut buf = vec![0u8; len];
    let n = file.read(&mut buf).map_err(|_| Error::new(EIO))?;
    buf.truncate(n);
    Ok(buf)
}

fn worker_write_at(
    root_fd: usize,
    profile_root_fd: Option<usize>,
    store_root_fd: Option<usize>,
    dev_null_fd: Option<usize>,
    dev_urandom_fd: Option<usize>,
    path: &Path,
    offset: u64,
    append: bool,
    data: &[u8],
) -> Result<WriteResult> {
    let clean = path.to_string_lossy();
    let clean = clean.trim_start_matches('/');
    if clean == "dev/null" || clean == "dev/zero" {
        return Ok(WriteResult {
            bytes_written: data.len(),
            end_offset: offset + data.len() as u64,
        });
    }

    let fd = open_fd(
        root_fd,
        profile_root_fd,
        store_root_fd,
        dev_null_fd,
        dev_urandom_fd,
        path,
        O_RDWR,
    )?;
    let mut file = unsafe { File::from_raw_fd(fd as i32) };
    let write_offset = if append {
        file.seek(SeekFrom::End(0)).map_err(|_| Error::new(EIO))?
    } else {
        file.seek(SeekFrom::Start(offset))
            .map_err(|_| Error::new(EIO))?;
        offset
    };
    let n = file.write(data).map_err(|_| Error::new(EIO))?;
    Ok(WriteResult {
        bytes_written: n,
        end_offset: write_offset + n as u64,
    })
}

fn worker_stat_path(
    root_fd: usize,
    profile_root_fd: Option<usize>,
    store_root_fd: Option<usize>,
    dev_null_fd: Option<usize>,
    dev_urandom_fd: Option<usize>,
    path: &Path,
    directory: bool,
) -> Result<Stat> {
    let flags = if directory {
        O_RDONLY | O_DIRECTORY
    } else {
        O_RDONLY
    };
    let fd = open_fd(
        root_fd,
        profile_root_fd,
        store_root_fd,
        dev_null_fd,
        dev_urandom_fd,
        path,
        flags,
    )?;
    let stat = raw_fstat(fd)?;
    raw_close(fd);
    Ok(stat)
}

fn worker_chmod_path(
    root_fd: usize,
    profile_root_fd: Option<usize>,
    store_root_fd: Option<usize>,
    dev_null_fd: Option<usize>,
    dev_urandom_fd: Option<usize>,
    path: &Path,
    directory: bool,
    new_mode: u16,
) -> Result<()> {
    let flags = if directory {
        O_RDONLY | O_DIRECTORY
    } else {
        O_RDONLY
    };
    let fd = open_fd(
        root_fd,
        profile_root_fd,
        store_root_fd,
        dev_null_fd,
        dev_urandom_fd,
        path,
        flags,
    )?;
    let result = unsafe { syscall::syscall2(syscall::SYS_FCHMOD, fd, new_mode as usize) };
    raw_close(fd);
    result.map(|_| ())
}

fn worker_truncate_path(
    root_fd: usize,
    profile_root_fd: Option<usize>,
    store_root_fd: Option<usize>,
    dev_null_fd: Option<usize>,
    dev_urandom_fd: Option<usize>,
    path: &Path,
    len: u64,
) -> Result<()> {
    let fd = open_fd(
        root_fd,
        profile_root_fd,
        store_root_fd,
        dev_null_fd,
        dev_urandom_fd,
        path,
        O_RDWR,
    )?;
    let mut file = unsafe { File::from_raw_fd(fd as i32) };
    file.set_len(len).map_err(|_| Error::new(EIO))
}

fn worker_resolve_path(
    root_fd: usize,
    profile_root_fd: Option<usize>,
    store_root_fd: Option<usize>,
    dev_null_fd: Option<usize>,
    dev_urandom_fd: Option<usize>,
    path: &Path,
) -> Result<PathBuf> {
    let fd = open_fd(
        root_fd,
        profile_root_fd,
        store_root_fd,
        dev_null_fd,
        dev_urandom_fd,
        path,
        O_RDONLY,
    )?;
    let resolved = raw_fpath(fd).ok_or(Error::new(EIO))?;
    raw_close(fd);
    Ok(resolved)
}

fn worker_rename_path(
    root_fd: usize,
    profile_root_fd: Option<usize>,
    store_root_fd: Option<usize>,
    dev_null_fd: Option<usize>,
    dev_urandom_fd: Option<usize>,
    old_path: &Path,
    new_path: &Path,
) -> Result<()> {
    let fd = open_fd(
        root_fd,
        profile_root_fd,
        store_root_fd,
        dev_null_fd,
        dev_urandom_fd,
        old_path,
        O_RDONLY,
    )?;
    let new_path = new_path.to_string_lossy();
    let result = syscall::frename(fd, new_path.as_ref()).map(|_| ());
    raw_close(fd);
    result
}

fn worker_mmap_path(
    root_fd: usize,
    profile_root_fd: Option<usize>,
    store_root_fd: Option<usize>,
    dev_null_fd: Option<usize>,
    dev_urandom_fd: Option<usize>,
    path: &Path,
    offset: u64,
    size: usize,
    flags: MapFlags,
    next_map_token: &mut u64,
    active_maps: &mut HashMap<u64, ActiveMap>,
) -> Result<MmapResult> {
    let open_flags = if flags.contains(MapFlags::PROT_WRITE) {
        O_RDWR
    } else {
        O_RDONLY
    };
    let fd = open_fd(
        root_fd,
        profile_root_fd,
        store_root_fd,
        dev_null_fd,
        dev_urandom_fd,
        path,
        open_flags,
    )?;
    let map = Map {
        offset: offset as usize,
        size,
        flags,
        address: 0,
    };

    let base_addr = match unsafe { syscall::fmap(fd, &map) } {
        Ok(base_addr) => base_addr,
        Err(err) => {
            raw_close(fd);
            return Err(err);
        }
    };

    let token = *next_map_token;
    *next_map_token = next_map_token.wrapping_add(1).max(1);
    active_maps.insert(
        token,
        ActiveMap {
            base_addr,
            len: size,
            backing_fd: fd,
        },
    );

    Ok(MmapResult { token, base_addr })
}

fn worker_munmap_token(token: u64, active_maps: &mut HashMap<u64, ActiveMap>) -> Result<()> {
    let active_map = active_maps.remove(&token).ok_or(Error::new(EBADF))?;
    unsafe { syscall::funmap(active_map.base_addr, active_map.len) }?;
    raw_close(active_map.backing_fd);
    Ok(())
}

fn worker_read_dir(
    root_fd: usize,
    profile_root_fd: Option<usize>,
    store_root_fd: Option<usize>,
    dev_null_fd: Option<usize>,
    dev_urandom_fd: Option<usize>,
    rustlib_dir_cache: &HashMap<PathBuf, Vec<(String, DirentKind)>>,
    path: &Path,
) -> Result<Vec<(String, DirentKind)>> {
    let trace_rustlib = path.to_string_lossy().contains("rustlib");
    let dir_fd = open_fd(
        root_fd,
        profile_root_fd,
        store_root_fd,
        dev_null_fd,
        dev_urandom_fd,
        path,
        O_RDONLY | O_DIRECTORY,
    )?;
    let resolved_path = path.to_path_buf();
    if trace_rustlib {
        eprintln!(
            "buildfs-io: read_dir request={:?} resolved={:?}",
            path, resolved_path
        );
        eprintln!(
            "buildfs-io: read_dir opened final fpath={:?}",
            raw_fpath(dir_fd)
        );
    }

    let mut entries = Vec::new();
    let mut raw_buf = [0u8; 8192];

    loop {
        let n = match unsafe {
            syscall::syscall3(
                syscall::SYS_GETDENTS,
                dir_fd,
                raw_buf.as_mut_ptr() as usize,
                raw_buf.len(),
            )
        } {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) => {
                raw_close(dir_fd);
                return Err(e);
            }
        };

        let before = entries.len();
        parse_raw_dirents(&raw_buf[..n], &mut entries);
        if trace_rustlib {
            let added = &entries[before..];
            let sample: Vec<_> = added.iter().take(8).map(|(name, _)| name.clone()).collect();
            eprintln!(
                "buildfs-io: read_dir chunk bytes={} parsed={} sample={:?}",
                n,
                added.len(),
                sample
            );
        }
    }

    if entries.is_empty() {
        let cache_key = PathBuf::from(path.to_string_lossy().trim_start_matches('/'));
        if let Some(cached) = rustlib_dir_cache.get(&cache_key) {
            if trace_rustlib {
                eprintln!(
                    "buildfs-io: read_dir using pre-scanned cache for {:?} ({} entries)",
                    cache_key,
                    cached.len()
                );
            }
            entries = cached.clone();
        } else if trace_rustlib {
            let sample_keys: Vec<_> = rustlib_dir_cache
                .keys()
                .take(8)
                .map(|key| key.display().to_string())
                .collect();
            eprintln!(
                "buildfs-io: cache miss for {:?}; known keys={:?}",
                cache_key, sample_keys
            );
        }
    }

    if trace_rustlib {
        let sample: Vec<_> = entries
            .iter()
            .take(8)
            .map(|(name, _)| name.clone())
            .collect();
        eprintln!(
            "buildfs-io: read_dir final count={} sample={:?}",
            entries.len(),
            sample
        );
    }
    raw_close(dir_fd);
    Ok(entries)
}

fn open_fd(
    root_fd: usize,
    profile_root_fd: Option<usize>,
    store_root_fd: Option<usize>,
    dev_null_fd: Option<usize>,
    dev_urandom_fd: Option<usize>,
    path: &Path,
    flags: usize,
) -> Result<usize> {
    let path_str = path.to_string_lossy();
    let clean = path_str.trim_start_matches('/');

    if clean == "dev/null" {
        return syscall::dup(dev_null_fd.ok_or(Error::new(EIO))?, &[]);
    }
    if clean == "dev/urandom" || clean == "dev/random" {
        return syscall::dup(dev_urandom_fd.ok_or(Error::new(EIO))?, &[]);
    }
    if clean == "nix/system/profile/lib/rustlib" {
        if let Some(mapped) = map_profile_rustlib_path("") {
            if let Some(rest) = mapped.strip_prefix("/nix/store/") {
                return raw_openat(store_root_fd.ok_or(Error::new(EIO))?, rest, flags);
            }
            return raw_openat(root_fd, mapped.trim_start_matches('/'), flags);
        }
    }
    if let Some(rest) = clean.strip_prefix("nix/system/profile/lib/rustlib/") {
        if let Some(mapped) = map_profile_rustlib_path(rest) {
            if let Some(store_rest) = mapped.strip_prefix("/nix/store/") {
                return raw_openat(store_root_fd.ok_or(Error::new(EIO))?, store_rest, flags);
            }
            return raw_openat(root_fd, mapped.trim_start_matches('/'), flags);
        }
    }
    if clean == "nix/system/profile" {
        return raw_openat(profile_root_fd.ok_or(Error::new(EIO))?, ".", flags);
    }
    if let Some(rest) = clean.strip_prefix("nix/system/profile/") {
        return raw_openat(profile_root_fd.ok_or(Error::new(EIO))?, rest, flags);
    }
    if clean == "nix/store" {
        return raw_openat(store_root_fd.ok_or(Error::new(EIO))?, ".", flags);
    }
    if let Some(rest) = clean.strip_prefix("nix/store/") {
        return raw_openat(store_root_fd.ok_or(Error::new(EIO))?, rest, flags);
    }

    raw_openat(root_fd, clean, flags)
}

fn map_profile_rustlib_path(rest: &str) -> Option<String> {
    let root = std::env::var("SNIX_PROFILE_RUSTLIB_ROOT").ok()?;
    if rest.is_empty() {
        Some(root)
    } else {
        Some(format!("{root}/{}", rest.trim_start_matches('/')))
    }
}

fn raw_openat(root_fd: usize, path: &str, flags: usize) -> Result<usize> {
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

fn raw_fpath(fd: usize) -> Option<PathBuf> {
    let mut buf = vec![0u8; 4096];
    let len = syscall::fpath(fd, &mut buf).ok()?;
    buf.truncate(len);
    let nul = buf.iter().position(|b| *b == 0).unwrap_or(buf.len());
    let s = std::str::from_utf8(&buf[..nul]).ok()?;
    let s = s.strip_prefix("file:").unwrap_or(s);
    let s = s.strip_prefix("/scheme/file").unwrap_or(s);
    let s = if s.is_empty() { "/" } else { s };
    Some(PathBuf::from(s))
}

fn raw_fstat(fd: usize) -> Result<Stat> {
    let mut stat = Stat::default();
    let stat_ptr = &mut stat as *mut Stat as usize;
    let stat_size = core::mem::size_of::<Stat>();
    unsafe {
        syscall::syscall3(syscall::SYS_FSTAT, fd, stat_ptr, stat_size)?;
    }
    Ok(stat)
}

fn raw_close(fd: usize) {
    let _ = syscall::close(fd);
}

fn raw_mkdir(root_fd: usize, path: &str) -> Result<()> {
    let clean = path.trim_start_matches('/');
    let fd = raw_openat(root_fd, clean, O_CREAT | O_DIRECTORY)?;
    raw_close(fd);
    Ok(())
}

fn mkdir_p_via_root_fd(root_fd: usize, path: &Path) {
    let path_str = path.to_string_lossy();
    let clean = path_str.trim_start_matches('/');
    let mut built = String::new();
    for component in clean.split('/') {
        if component.is_empty() {
            continue;
        }
        if !built.is_empty() {
            built.push('/');
        }
        built.push_str(component);
        let _ = raw_mkdir(root_fd, &built);
    }
}

fn parse_raw_dirents(buf: &[u8], entries: &mut Vec<(String, DirentKind)>) {
    const HEADER_SIZE: usize = 8 + 8 + 2 + 1;

    let mut pos = 0;
    while pos + HEADER_SIZE <= buf.len() {
        let record_len = u16::from_ne_bytes(buf[pos + 16..pos + 18].try_into().unwrap_or([0; 2]));
        let kind_byte = buf[pos + 18];

        if record_len == 0 || pos + record_len as usize > buf.len() {
            break;
        }

        let name_start = pos + HEADER_SIZE;
        let name_end = pos + record_len as usize;
        let name_bytes = &buf[name_start..name_end];
        let nul = name_bytes
            .iter()
            .position(|b| *b == 0)
            .unwrap_or(name_bytes.len());

        if nul != 0 {
            if let Ok(name) = std::str::from_utf8(&name_bytes[..nul]) {
                if name != "." && name != ".." {
                    let kind = DirentKind::try_from_raw(kind_byte).unwrap_or(DirentKind::Regular);
                    entries.push((name.to_string(), kind));
                }
            }
        }

        pos += record_len as usize;
    }
}
