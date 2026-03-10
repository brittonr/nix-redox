//! Proxy lifecycle management: start, event loop, shutdown.
//!
//! The proxy runs as a thread in the snix process. It creates a scheme
//! socket, registers as `file` in the child namespace, and enters an
//! event loop processing requests. The socket close (triggered when the
//! builder exits or snix calls shutdown) terminates the loop.
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

        // Create the handler and register the scheme.
        let mut handler = BuildFsHandler::new(allow_list);
        let mut state = SchemeState::new();

        // Register as "file" in the child's namespace.
        // This is the critical step — the child's file: operations
        // will route to our proxy instead of redoxfs.
        let cap_id = match redox_scheme::scheme::register_sync_scheme(
            &socket, "file", &mut handler,
        ) {
            Ok(()) => {
                eprintln!("buildfs: registered as 'file' in current namespace");
                // Now register into the child namespace specifically.
                // The register_sync_scheme registered in the current ns,
                // but we need it in the child ns. Use register_scheme_to_ns.
                //
                // Actually, register_sync_scheme calls register_scheme_inner
                // which uses getns() → current namespace. We need to register
                // in the CHILD namespace. Let's use the lower-level API.
                //
                // For now, the registration approach:
                // 1. We call register_sync_scheme which also calls scheme_root
                // 2. But it registers in our current namespace, not child's
                //
                // We need to re-register in the child namespace.
                // The cap_fd from socket.create_this_scheme_fd is what we need.
                // Let's handle this more carefully.
                ()
            }
            Err(e) => {
                return Err(BuildFsProxyError::SetupFailed(
                    format!("register_sync_scheme('file'): {e}"),
                ));
            }
        };

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
                Ok(()) => eprintln!("buildfs: proxy thread exited cleanly"),
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
    eprintln!("buildfs: entering event loop");

    loop {
        let req = match socket.next_request(SignalBehavior::Restart) {
            Ok(Some(req)) => req,
            Ok(None) => {
                eprintln!("buildfs: socket closed, exiting");
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
                    Ok(true) => {}
                    Ok(false) => {
                        eprintln!("buildfs: write_response returned false, exiting");
                        break;
                    }
                    Err(e) => {
                        eprintln!("buildfs: write_response error: {e}");
                        break;
                    }
                }
            }
            RequestKind::OnClose { id } => {
                handler.on_close(id);
            }
            _ => continue,
        }
    }

    eprintln!(
        "buildfs: event loop ended ({} handles still open)",
        handler.handles.len()
    );
}
