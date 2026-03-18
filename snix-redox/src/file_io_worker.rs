//! Background file I/O worker for Redox scheme daemons.
//!
//! On Redox, scheme daemons cannot do filesystem I/O from within
//! the scheme event loop — any syscall that targets another scheme
//! (including `file:`) blocks the daemon thread indefinitely, because
//! the kernel won't deliver the scheme response while the daemon's
//! thread is blocked waiting for the file I/O result.
//!
//! This worker runs file I/O on a separate thread. The scheme handler
//! sends requests via a channel, and the worker does the actual
//! `fs::File::open()`, `seek()`, `read()` — then sends the result back.
//! The scheme handler blocks on the response channel, but the WORKER
//! thread can still receive kernel responses to its file: syscalls
//! because it's a different thread from the scheme event loop.
//!
//! Usage:
//! ```no_run
//! use snix_redox::file_io_worker::FileIoWorker;
//! use std::path::PathBuf;
//! let worker = FileIoWorker::spawn(None);
//!
//! // From within the scheme handler's read():
//! let path = PathBuf::from("/nix/store/abc/bin/rg");
//! let result = worker.read_file(&path, 0, 4096);
//! match result {
//!     Ok(data) => { /* copy to caller buffer */ }
//!     Err(e) => { /* return EBADF or EIO */ }
//! }
//! ```

use std::fs;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::PathBuf;
use std::sync::mpsc;
use std::thread;
use std::collections::BTreeMap;

/// Maximum number of cached open file descriptors. When exceeded,
/// the lexicographically first entry is evicted. Keeps the worker's
/// fd usage bounded for long-running daemons.
const MAX_FILE_CACHE: usize = 64;

/// Request sent from the scheme handler to the I/O worker.
enum IoRequest {
    /// Read bytes from a file at the given offset.
    Read {
        path: PathBuf,
        offset: u64,
        len: usize,
        response: mpsc::Sender<io::Result<Vec<u8>>>,
    },
    /// Pre-load entire file content into cache.
    Preload {
        path: PathBuf,
        response: mpsc::Sender<io::Result<Vec<u8>>>,
    },
    /// Shut down the worker.
    Shutdown,
}

/// A background file I/O worker thread.
///
/// Handles all filesystem access on behalf of scheme daemons,
/// keeping file operations off the scheme event loop thread.
pub struct FileIoWorker {
    sender: mpsc::Sender<IoRequest>,
    // The join handle is kept to ensure the thread lives as long as the worker.
    _handle: thread::JoinHandle<()>,
}

impl FileIoWorker {
    /// Spawn the worker thread.
    ///
    /// `root_fd`: On Redox, a pre-opened fd to `/` for bypassing
    /// initnsmgr after `setrens(0, 0)`. Pass `None` on Linux/tests
    /// to use `std::fs` (the default).
    pub fn spawn(root_fd: Option<usize>) -> Self {
        let (tx, rx) = mpsc::channel::<IoRequest>();

        let handle = thread::spawn(move || {
            // Cache of open file handles to avoid re-opening on each read.
            let mut file_cache: BTreeMap<PathBuf, fs::File> = BTreeMap::new();

            for request in rx.iter() {
                match request {
                    IoRequest::Read {
                        path,
                        offset,
                        len,
                        response,
                    } => {
                        let result = worker_read(&mut file_cache, &path, offset, len, root_fd);
                        // Ignore send errors — the receiver may have been dropped
                        // if the scheme handler timed out or the handle was closed.
                        let _ = response.send(result);
                    }
                    IoRequest::Preload { path, response } => {
                        let result = worker_preload(&path, root_fd);
                        let _ = response.send(result);
                    }
                    IoRequest::Shutdown => {
                        break;
                    }
                }
            }
        });

        Self {
            sender: tx,
            _handle: handle,
        }
    }

    /// Read bytes from a file at the given offset.
    ///
    /// Blocks until the worker thread completes the I/O. Safe to call
    /// from within a Redox scheme handler because the CALLER thread
    /// blocks on a channel receive, while the WORKER thread does the
    /// actual file: scheme I/O on a separate thread.
    pub fn read_file(
        &self,
        path: &PathBuf,
        offset: u64,
        len: usize,
    ) -> io::Result<Vec<u8>> {
        let (resp_tx, resp_rx) = mpsc::channel();
        self.sender
            .send(IoRequest::Read {
                path: path.clone(),
                offset,
                len,
                response: resp_tx,
            })
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "I/O worker dead"))?;

        resp_rx
            .recv()
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "I/O worker response lost"))?
    }

    /// Pre-load entire file content. Useful for small files where
    /// caching the full content avoids repeated I/O round-trips.
    pub fn preload_file(&self, path: &PathBuf) -> io::Result<Vec<u8>> {
        let (resp_tx, resp_rx) = mpsc::channel();
        self.sender
            .send(IoRequest::Preload {
                path: path.clone(),
                response: resp_tx,
            })
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "I/O worker dead"))?;

        resp_rx
            .recv()
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "I/O worker response lost"))?
    }
}

impl Drop for FileIoWorker {
    fn drop(&mut self) {
        // Best-effort shutdown. The worker will exit when the channel closes
        // even if the Shutdown message doesn't make it through.
        let _ = self.sender.send(IoRequest::Shutdown);
    }
}

/// Worker thread: open (or reuse cached) file, seek, read.
fn worker_read(
    cache: &mut BTreeMap<PathBuf, fs::File>,
    path: &PathBuf,
    offset: u64,
    len: usize,
    root_fd: Option<usize>,
) -> io::Result<Vec<u8>> {
    // Open file if not cached.
    if !cache.contains_key(path) {
        let file = open_file(path, root_fd)?;
        // Evict oldest entry if cache is full.
        if cache.len() >= MAX_FILE_CACHE {
            if let Some(oldest) = cache.keys().next().cloned() {
                cache.remove(&oldest);
            }
        }
        cache.insert(path.clone(), file);
    }

    let file = cache.get_mut(path).unwrap();
    file.seek(SeekFrom::Start(offset))?;

    let mut buf = vec![0u8; len];
    let n = file.read(&mut buf)?;
    buf.truncate(n);
    Ok(buf)
}

/// Worker thread: read entire file content.
fn worker_preload(path: &PathBuf, root_fd: Option<usize>) -> io::Result<Vec<u8>> {
    let mut file = open_file(path, root_fd)?;
    let mut data = Vec::new();
    file.read_to_end(&mut data)?;
    Ok(data)
}

/// Open a file, using raw `SYS_OPENAT(root_fd, ...)` on Redox when
/// a root_fd is available (bypasses initnsmgr after setrens), or
/// falling back to `std::fs::File::open()` on Linux/tests.
fn open_file(path: &PathBuf, root_fd: Option<usize>) -> io::Result<fs::File> {
    #[cfg(target_os = "redox")]
    if let Some(rfd) = root_fd {
        return open_via_root_fd(rfd, path);
    }

    #[cfg(not(target_os = "redox"))]
    let _ = root_fd;

    fs::File::open(path)
}

/// Redox-only: open a file via `SYS_OPENAT(root_fd, path, O_RDONLY)`.
/// The root_fd points directly to redoxfs, bypassing initnsmgr.
#[cfg(target_os = "redox")]
fn open_via_root_fd(root_fd: usize, path: &PathBuf) -> io::Result<fs::File> {
    use std::os::unix::io::FromRawFd;

    let path_str = path.to_string_lossy();
    let clean = path_str.trim_start_matches('/');
    // SYS_OPENAT: (fd, ptr, len, flags, fcntl_flags)
    let flags = syscall::O_RDONLY;
    let fcntl_flags = flags & syscall::O_FCNTL_MASK;
    let raw_fd = unsafe {
        syscall::syscall5(
            syscall::SYS_OPENAT,
            root_fd,
            clean.as_ptr() as usize,
            clean.len(),
            flags,
            fcntl_flags,
        )
    }
    .map_err(|e| io::Error::new(io::ErrorKind::NotFound, format!("SYS_OPENAT: {e}")))?;

    Ok(unsafe { fs::File::from_raw_fd(raw_fd as i32) })
}

// ── Tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn read_file_basic() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("test.txt");
        fs::write(&path, "Hello World!").unwrap();

        let worker = FileIoWorker::spawn(None);
        let data = worker.read_file(&path, 0, 1024).unwrap();
        assert_eq!(&data, b"Hello World!");
    }

    #[test]
    fn read_file_at_offset() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("offset.txt");
        fs::write(&path, "Hello World!").unwrap();

        let worker = FileIoWorker::spawn(None);
        let data = worker.read_file(&path, 6, 1024).unwrap();
        assert_eq!(&data, b"World!");
    }

    #[test]
    fn read_file_small_buffer() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("small.txt");
        fs::write(&path, "Hello World!").unwrap();

        let worker = FileIoWorker::spawn(None);
        let data = worker.read_file(&path, 0, 5).unwrap();
        assert_eq!(&data, b"Hello");
    }

    #[test]
    fn read_file_cached_reopen() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("cached.txt");
        fs::write(&path, "First read").unwrap();

        let worker = FileIoWorker::spawn(None);

        // First read opens the file.
        let data1 = worker.read_file(&path, 0, 1024).unwrap();
        assert_eq!(&data1, b"First read");

        // Second read uses the cached handle.
        let data2 = worker.read_file(&path, 5, 1024).unwrap();
        assert_eq!(&data2, b" read");
    }

    #[test]
    fn read_nonexistent_file() {
        let worker = FileIoWorker::spawn(None);
        let result = worker.read_file(&PathBuf::from("/nonexistent"), 0, 64);
        assert!(result.is_err());
    }

    #[test]
    fn preload_file_basic() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("preload.txt");
        fs::write(&path, "Preloaded content").unwrap();

        let worker = FileIoWorker::spawn(None);
        let data = worker.preload_file(&path).unwrap();
        assert_eq!(&data, b"Preloaded content");
    }

    #[test]
    fn multiple_files() {
        let tmp = tempfile::tempdir().unwrap();
        let p1 = tmp.path().join("a.txt");
        let p2 = tmp.path().join("b.txt");
        fs::write(&p1, "alpha").unwrap();
        fs::write(&p2, "bravo").unwrap();

        let worker = FileIoWorker::spawn(None);
        assert_eq!(worker.read_file(&p1, 0, 64).unwrap(), b"alpha");
        assert_eq!(worker.read_file(&p2, 0, 64).unwrap(), b"bravo");
    }

    #[test]
    fn drop_shuts_down() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("drop.txt");
        fs::write(&path, "data").unwrap();

        let worker = FileIoWorker::spawn(None);
        let data = worker.read_file(&path, 0, 64).unwrap();
        assert_eq!(&data, b"data");
        drop(worker); // Should not panic or hang.
    }

    #[test]
    fn cache_eviction_at_limit() {
        let tmp = tempfile::tempdir().unwrap();

        // Create MAX_FILE_CACHE + 5 files.
        for i in 0..MAX_FILE_CACHE + 5 {
            let path = tmp.path().join(format!("file_{:04}.txt", i));
            fs::write(&path, format!("content {i}")).unwrap();
        }

        let worker = FileIoWorker::spawn(None);

        // Read all files — the cache should evict oldest entries
        // once it exceeds MAX_FILE_CACHE. All reads should succeed.
        for i in 0..MAX_FILE_CACHE + 5 {
            let path = tmp.path().join(format!("file_{:04}.txt", i));
            let data = worker.read_file(&path, 0, 1024).unwrap();
            assert_eq!(data, format!("content {i}").as_bytes());
        }

        // Re-read an early file that was likely evicted — should re-open.
        let path = tmp.path().join("file_0000.txt");
        let data = worker.read_file(&path, 0, 1024).unwrap();
        assert_eq!(&data, b"content 0");
    }
}
