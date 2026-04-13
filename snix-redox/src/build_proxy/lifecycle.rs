//! Proxy lifecycle management: helper subprocess, event loop, shutdown.
//!
//! The build proxy runs in a dedicated helper process. That helper:
//! 1. owns the scheme socket registered as `file` in the builder namespace
//! 2. pre-opens `/` and device handles for direct redoxfs/device access
//! 3. calls `setrens(0, 0)` to drop out of initnsmgr's namespace
//! 4. runs the scheme event loop plus a worker thread for real I/O
//!
//! Process split matters: `setrens(0, 0)` is process-wide. Doing it in a
//! thread inside `snix` breaks the parent build process. Running the proxy in
//! a helper subprocess lets the parent stay in its normal namespace.
//!
//! Only compiled on Redox (`#[cfg(target_os = "redox")]`).

use std::fs::File;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use redox_scheme::scheme::{SchemeState, SchemeSync};
use redox_scheme::{RequestKind, SignalBehavior, Socket};

use super::allow_list::AllowList;
use super::handler::BuildFsHandler;
use super::io_worker::BuildFsIoWorker;
use super::BuildFsProxyError;

static ALLOW_LIST_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Running build filesystem proxy helper process.
pub struct BuildFsProxy {
    child: Option<Child>,
    allow_list_file: Option<PathBuf>,
    ready_file: Option<PathBuf>,
}

impl BuildFsProxy {
    /// Start proxy helper and wait until it has registered `file:` in the
    /// child namespace and entered the null namespace.
    pub fn start(child_ns_fd: usize, allow_list: AllowList) -> Result<Self, BuildFsProxyError> {
        let allow_list_file = write_allow_list_file(&allow_list)?;
        let ready_file = write_ready_file_path()?;
        let exe = current_exe_path()?;

        let mut cmd = Command::new(&exe);
        cmd.arg("build-proxy-helper")
            .arg(child_ns_fd.to_string())
            .arg(&allow_list_file)
            .arg(&ready_file)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit());

        let mut child = cmd.spawn().map_err(|e| {
            BuildFsProxyError::SetupFailed(format!("spawn proxy helper '{exe}': {e}"))
        })?;

        if !wait_for_ready(&ready_file, &mut child, 200) {
            let status = child.wait().ok();
            let _ = std::fs::remove_file(&allow_list_file);
            let _ = std::fs::remove_file(&ready_file);
            return Err(BuildFsProxyError::SetupFailed(format!(
                "proxy helper failed to become ready (status={status:?})"
            )));
        }

        Ok(Self {
            child: Some(child),
            allow_list_file: Some(allow_list_file),
            ready_file: Some(ready_file),
        })
    }

    /// Parent keeps no scheme socket fd. Only helper owns it.
    pub fn socket_fd(&self) -> Option<usize> {
        None
    }

    /// Helper subprocess entrypoint.
    pub fn run_helper(
        child_ns_fd: usize,
        allow_list_file: &str,
        ready_file: &str,
    ) -> Result<(), BuildFsProxyError> {
        let allow_list = read_allow_list_file(Path::new(allow_list_file))?;

        eprintln!("buildfs: creating socket");
        let socket = Socket::create()
            .map_err(|e| BuildFsProxyError::SetupFailed(format!("Socket::create: {e}")))?;
        eprintln!("buildfs: socket created");

        eprintln!("buildfs: creating cap fd");
        let cap_fd = socket
            .create_this_scheme_fd(0, 0, 0, 0)
            .map_err(|e| BuildFsProxyError::SetupFailed(format!("create_this_scheme_fd: {e}")))?;

        eprintln!("buildfs: registering in ns_fd={}", child_ns_fd);
        libredox::call::register_scheme_to_ns(child_ns_fd, "file", cap_fd).map_err(|e| {
            BuildFsProxyError::SetupFailed(format!("register_scheme_to_ns('file'): {e}"))
        })?;
        eprintln!("buildfs: registered");
        let _ = syscall::close(cap_fd);
        let _ = syscall::close(child_ns_fd);

        eprintln!("buildfs: pre-opening /");
        let root_file =
            File::open("/").map_err(|e| BuildFsProxyError::SetupFailed(format!("open /: {e}")))?;
        let dev_null = File::open("/dev/null").ok();
        let dev_urandom = File::open("/dev/urandom").ok();

        let io_worker = BuildFsIoWorker::spawn(root_file, dev_null, dev_urandom);
        let mut handler = BuildFsHandler::new(allow_list, io_worker);
        handler.install_root_handle(0);
        let state = SchemeState::new();
        let mut ready = std::fs::File::create(ready_file).map_err(|e| {
            BuildFsProxyError::SetupFailed(format!("create ready file {ready_file}: {e}"))
        })?;

        eprintln!("buildfs: entering null namespace");
        libredox::call::setrens(0, 0)
            .map_err(|e| BuildFsProxyError::SetupFailed(format!("setrens(0, 0): {e}")))?;

        ready.write_all(b"READY\n").ok();
        ready.flush().ok();

        run_event_loop(socket, handler, state);
        Ok(())
    }

    pub fn shutdown(mut self) {
        self.close_and_join();
    }

    fn close_and_join(&mut self) {
        if let Some(mut child) = self.child.take() {
            eprintln!("buildfs: waiting for proxy helper pid={}", child.id());
            let exited = wait_for_exit(&mut child, 200);
            if !exited {
                eprintln!(
                    "buildfs: proxy helper still alive, killing pid={}",
                    child.id()
                );
                let _ = child.kill();
                let _ = child.wait();
            }
            eprintln!("buildfs: proxy helper reaped");
        }

        if let Some(path) = self.allow_list_file.take() {
            let _ = std::fs::remove_file(path);
        }
        if let Some(path) = self.ready_file.take() {
            let _ = std::fs::remove_file(path);
        }
    }
}

impl Drop for BuildFsProxy {
    fn drop(&mut self) {
        self.close_and_join();
    }
}

fn wait_for_exit(child: &mut Child, attempts: usize) -> bool {
    for _ in 0..attempts {
        match child.try_wait() {
            Ok(Some(_)) => return true,
            Ok(None) => std::thread::sleep(Duration::from_millis(10)),
            Err(_) => return false,
        }
    }
    false
}

fn wait_for_ready(path: &Path, child: &mut Child, attempts: usize) -> bool {
    for _ in 0..attempts {
        if let Ok(content) = std::fs::read_to_string(path) {
            if content.trim() == "READY" {
                return true;
            }
        }
        match child.try_wait() {
            Ok(Some(_)) => return false,
            Ok(None) => std::thread::sleep(Duration::from_millis(10)),
            Err(_) => return false,
        }
    }
    false
}

fn current_exe_path() -> Result<String, BuildFsProxyError> {
    let exe = std::env::current_exe()
        .map_err(|e| BuildFsProxyError::SetupFailed(format!("current_exe: {e}")))?;
    let exe_str = exe.to_string_lossy();
    Ok(exe_str
        .strip_prefix("file:")
        .unwrap_or(&exe_str)
        .to_string())
}

fn write_ready_file_path() -> Result<PathBuf, BuildFsProxyError> {
    let id = ALLOW_LIST_COUNTER.fetch_add(1, Ordering::Relaxed);
    let pid = std::process::id();
    let path = std::env::temp_dir().join(format!("snix-buildfs-ready-{pid}-{id}.txt"));
    let _ = std::fs::remove_file(&path);
    Ok(path)
}

fn write_allow_list_file(allow_list: &AllowList) -> Result<PathBuf, BuildFsProxyError> {
    let id = ALLOW_LIST_COUNTER.fetch_add(1, Ordering::Relaxed);
    let pid = std::process::id();
    let path = std::env::temp_dir().join(format!("snix-buildfs-allow-{pid}-{id}.txt"));
    let mut file = std::fs::File::create(&path)
        .map_err(|e| BuildFsProxyError::SetupFailed(format!("create allow-list file: {e}")))?;

    for path in &allow_list.read_only {
        writeln!(file, "ro\t{}", path.display()).map_err(|e| {
            BuildFsProxyError::SetupFailed(format!("write allow-list file {}: {e}", path.display()))
        })?;
    }
    for path in &allow_list.read_write {
        writeln!(file, "rw\t{}", path.display()).map_err(|e| {
            BuildFsProxyError::SetupFailed(format!("write allow-list file {}: {e}", path.display()))
        })?;
    }

    Ok(path)
}

fn read_allow_list_file(path: &Path) -> Result<AllowList, BuildFsProxyError> {
    let content = std::fs::read_to_string(path).map_err(|e| {
        BuildFsProxyError::SetupFailed(format!("read allow-list file {}: {e}", path.display()))
    })?;

    let mut allow_list = AllowList::new();
    for line in content.lines() {
        let Some((kind, rest)) = line.split_once('\t') else {
            continue;
        };
        let path = PathBuf::from(rest);
        match kind {
            "ro" => {
                allow_list.read_only.insert(path);
            }
            "rw" => {
                allow_list.read_write.insert(path);
            }
            _ => {}
        }
    }
    Ok(allow_list)
}

/// Proxy event loop.
fn run_event_loop(socket: Socket, mut handler: BuildFsHandler, mut state: SchemeState) {
    eprintln!("buildfs: entering event loop");
    loop {
        let req = match socket.next_request(SignalBehavior::Restart) {
            Ok(Some(req)) => {
                eprintln!("buildfs: got request");
                req
            }
            Ok(None) => {
                eprintln!("buildfs: socket closed");
                break;
            }
            Err(e) => {
                eprintln!("buildfs: next_request error: {e}");
                break;
            }
        };

        match req.kind() {
            RequestKind::Call(call_req) => {
                let response = call_req.handle_sync(&mut handler, &mut state);
                match socket.write_response(response, SignalBehavior::Restart) {
                    Ok(true) => eprintln!("buildfs: response sent"),
                    Ok(false) => break,
                    Err(_) => break,
                }
            }
            RequestKind::OnClose { id } => handler.on_close(id),
            _ => continue,
        }

        if handler.had_client_opens && handler.handles.is_empty() {
            eprintln!("buildfs: all handles closed, exiting event loop");
            break;
        }
    }
    eprintln!("buildfs: event loop exited");
}
