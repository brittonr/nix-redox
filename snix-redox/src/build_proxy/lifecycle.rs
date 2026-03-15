//! Proxy lifecycle management: start, event loop, shutdown.
//!
//! The proxy runs as a thread in the snix process. It creates a scheme
//! socket, registers as `file` in the child namespace, and enters an
//! event loop processing requests. The socket close (triggered when the
//! builder exits or snix calls shutdown) terminates the loop.
//!
//! ## Known limitation: file: I/O deadlock
//!
//! The proxy thread (and ALL threads in the snix process) CANNOT do
//! `file:` I/O while owning the scheme socket. The kernel prevents any
//! context in a scheme-socket-owning process from making `file:` requests,
//! even to a different `file:` scheme instance in a different namespace.
//!
//! This means the handler CANNOT open real files to forward them.
//! A working implementation requires either:
//! - A separate proxy process (fork, not thread) for real file I/O
//! - Pre-reading all files into memory before starting the event loop
//! - Kernel changes to allow cross-namespace file: I/O from scheme owners
//!
//! Only compiled on Redox (`#[cfg(target_os = "redox")]`).

use std::panic;
use std::thread::{self, JoinHandle};

use redox_scheme::scheme::{SchemeState, SchemeSync};
use redox_scheme::{RequestKind, SignalBehavior, Socket};

use super::allow_list::AllowList;
use super::handler::BuildFsHandler;
use super::BuildFsProxyError;

/// A running build filesystem proxy.
///
/// Holds the thread handle and socket fd. Dropping or calling
/// `shutdown()` closes the socket and joins the thread.
pub struct BuildFsProxy {
    /// The proxy event loop thread.
    thread: Option<JoinHandle<()>>,
    /// The raw socket fd — closing it terminates the event loop.
    /// Wrapped in Option so we can take it during shutdown.
    socket_fd: Option<usize>,
}

impl BuildFsProxy {
    /// Start the proxy: create socket, register in child namespace, spawn thread.
    ///
    /// `child_ns_fd`: namespace fd from `mkns()` (without `file`).
    /// `allow_list`: paths the builder is permitted to access.
    ///
    /// After this returns, the proxy is running and ready to handle
    /// requests from a child that calls `setns(child_ns_fd)`.
    pub fn start(
        child_ns_fd: usize,
        allow_list: AllowList,
    ) -> Result<Self, BuildFsProxyError> {
        // Create a scheme socket.
        let socket = Socket::create().map_err(|e| {
            BuildFsProxyError::SetupFailed(format!("Socket::create: {e}"))
        })?;

        // Get the raw fd before moving the socket into the thread.
        // We need it for shutdown (close the fd to stop the event loop).
        let socket_fd = socket.inner().raw();

        // Create the handler.
        let mut handler = BuildFsHandler::new(allow_list);
        let mut state = SchemeState::new();

        // Get the root handle ID from the scheme handler.
        let cap_id = handler.scheme_root().map_err(|e| {
            BuildFsProxyError::SetupFailed(format!("scheme_root: {e}"))
        })?;

        // Register as "file" in the CHILD namespace (not the parent's).
        //
        // register_sync_scheme() internally calls getns() which returns
        // the parent's namespace — where file: already exists (redoxfs).
        // Instead, we use the low-level API:
        //   1. create_this_scheme_fd() — get a capability fd from the socket
        //   2. register_scheme_to_ns(child_ns_fd, ...) — register in child ns
        //
        // The proxy thread runs in the parent namespace (so std::fs hits
        // real redoxfs), but the scheme is registered in the child namespace
        // (so the builder's file: operations route to our proxy).
        let cap_fd = socket.create_this_scheme_fd(0, cap_id, 0, 0).map_err(|e| {
            BuildFsProxyError::SetupFailed(
                format!("create_this_scheme_fd: {e}"),
            )
        })?;

        libredox::call::register_scheme_to_ns(child_ns_fd, "file", cap_fd)
            .map_err(|e| {
                BuildFsProxyError::SetupFailed(
                    format!("register_scheme_to_ns('file'): {e}"),
                )
            })?;

        // Spawn the event loop thread.
        let thread = thread::Builder::new()
            .name("buildfs-proxy".to_string())
            .spawn(move || {
                let result = panic::catch_unwind(panic::AssertUnwindSafe(|| {
                    run_event_loop(socket, handler, state);
                }));
                if let Err(e) = result {
                    eprintln!("buildfs: proxy thread panicked: {e:?}");
                }
            })
            .map_err(|e| {
                BuildFsProxyError::SetupFailed(format!("thread spawn: {e}"))
            })?;

        Ok(Self {
            thread: Some(thread),
            socket_fd: Some(socket_fd),
        })
    }

    /// Shut down the proxy: close the socket and join the thread.
    ///
    /// The socket close causes `socket.next_request()` in the event
    /// loop to return `None`, which exits the loop.
    pub fn shutdown(mut self) {
        self.close_and_join();
    }

    fn close_and_join(&mut self) {
        // Close the socket fd to signal the event loop to stop.
        if let Some(fd) = self.socket_fd.take() {
            let _ = syscall::close(fd);
        }

        // Join the thread.
        if let Some(thread) = self.thread.take() {
            match thread.join() {
                Ok(()) => {}
                Err(e) => eprintln!("buildfs: proxy thread join error: {e:?}"),
            }
        }
    }
}

impl Drop for BuildFsProxy {
    fn drop(&mut self) {
        self.close_and_join();
    }
}

/// The proxy event loop — processes scheme requests until the socket closes.
fn run_event_loop(
    socket: Socket,
    mut handler: BuildFsHandler,
    mut state: SchemeState,
) {
    loop {
        let req = match socket.next_request(SignalBehavior::Restart) {
            Ok(Some(req)) => req,
            Ok(None) => break,
            Err(_) => break,
        };

        match req.kind() {
            RequestKind::Call(call_req) => {
                let response = call_req.handle_sync(&mut handler, &mut state);
                match socket.write_response(response, SignalBehavior::Restart) {
                    Ok(true) => {}
                    Ok(false) => break,
                    Err(_) => break,
                }
            }
            RequestKind::OnClose { id } => {
                handler.on_close(id);
            }
            _ => continue,
        }
    }
}
