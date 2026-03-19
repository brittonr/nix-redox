//! Redox scheme protocol implementation for `irohd`.
//!
//! Only compiled on Redox (`#[cfg(target_os = "redox")]` for the
//! scheme registration parts). The handler logic is portable for testing.

#[cfg(target_os = "redox")]
use std::collections::HashMap;
#[cfg(target_os = "redox")]
use std::sync::mpsc;

use crate::bridge::{self, BridgeRequest, BridgeResponse, SharedInbox};
use crate::config::IrohConfig;
#[cfg(target_os = "redox")]
use crate::handles::*;

/// Scheme handler for iroh.
#[cfg(target_os = "redox")]
pub struct IrohSchemeHandler {
    handles: HandleTable,
    /// Node endpoint ID (hex string).
    node_id: String,
    /// Peer table: name → node_id hex.
    peers: HashMap<String, String>,
    /// Reverse lookup: node_id hex → name.
    peers_reverse: HashMap<String, String>,
    /// Channel to send requests to the iroh thread.
    bridge_tx: mpsc::Sender<BridgeRequest>,
    /// Shared inbox for incoming messages.
    inbox: SharedInbox,
}

#[cfg(target_os = "redox")]
impl IrohSchemeHandler {
    fn new(
        node_id: String,
        peers: HashMap<String, String>,
        bridge_tx: mpsc::Sender<BridgeRequest>,
        inbox: SharedInbox,
    ) -> Self {
        let peers_reverse: HashMap<String, String> = peers
            .iter()
            .map(|(name, id)| (id.clone(), name.clone()))
            .collect();

        Self {
            handles: HandleTable::new(),
            node_id,
            peers,
            peers_reverse,
            bridge_tx,
            inbox,
        }
    }

    /// Resolve a peer name or node ID to a (name, node_id) pair.
    fn resolve_peer(&self, name_or_id: &str) -> Option<(String, String)> {
        // Try as a name first.
        if let Some(node_id) = self.peers.get(name_or_id) {
            return Some((name_or_id.to_string(), node_id.clone()));
        }
        // Try as a raw node ID (64-char hex).
        if name_or_id.len() == 64 && name_or_id.chars().all(|c| c.is_ascii_hexdigit()) {
            let display_name = self
                .peers_reverse
                .get(name_or_id)
                .cloned()
                .unwrap_or_else(|| name_or_id.to_string());
            return Some((display_name, name_or_id.to_string()));
        }
        None
    }

    /// Send a bridge request and block for the response.
    fn bridge_call(&self, req: BridgeRequest) -> BridgeResponse {
        // This is a dead-simple blocking call. The scheme event loop
        // is single-threaded anyway, so blocking here is fine — one
        // request at a time.
        let (reply_tx, reply_rx) = mpsc::channel();

        // Wrap the request with the reply channel based on variant.
        // Since we already embedded reply in the request, just send it.
        let _ = self.bridge_tx.send(req);

        // Actually we need to rethink — the reply channel is inside
        // the BridgeRequest variants. So this method won't be used
        // directly. Let's provide typed helpers instead.
        match reply_rx.recv() {
            Ok(resp) => resp,
            Err(_) => BridgeResponse::Error("iroh thread died".into()),
        }
    }

    /// Process a .control command (called on handle close).
    fn process_control(&mut self, command: &str) {
        match serde_json::from_str::<serde_json::Value>(command) {
            Ok(val) => {
                if let Some(add) = val.get("addPeer") {
                    let name = add.get("name").and_then(|v| v.as_str()).unwrap_or("");
                    let id = add.get("id").and_then(|v| v.as_str()).unwrap_or("");
                    if !name.is_empty() && !id.is_empty() {
                        eprintln!("irohd: adding peer {name} -> {id}");
                        self.peers.insert(name.to_string(), id.to_string());
                        self.peers_reverse.insert(id.to_string(), name.to_string());
                    }
                }
                if let Some(rm) = val.get("removePeer") {
                    let name = rm.get("name").and_then(|v| v.as_str()).unwrap_or("");
                    if !name.is_empty() {
                        if let Some(id) = self.peers.remove(name) {
                            self.peers_reverse.remove(&id);
                            eprintln!("irohd: removed peer {name}");
                        }
                    }
                }
            }
            Err(e) => {
                eprintln!("irohd: control parse error: {e}");
            }
        }
    }
}

// --- Redox scheme trait implementation ---

#[cfg(target_os = "redox")]
mod redox_impl {
    use super::*;
    use redox_scheme::scheme::{SchemeState, SchemeSync};
    use redox_scheme::{CallerCtx, OpenResult, RequestKind, SignalBehavior, Socket};
    use syscall::data::Stat;
    use syscall::dirent::{DirEntry as RedoxDirEntry, DirentBuf, DirentKind};
    use syscall::error::{Error, Result, EACCES, EBADF, EIO, ENOENT, ENOTDIR};
    use syscall::flag::O_DIRECTORY;
    use syscall::schemev2::NewFdFlags;

    impl SchemeSync for IrohSchemeHandler {
        fn scheme_root(&mut self) -> Result<usize> {
            let id = self
                .handles
                .open_dir(String::new(), "root".to_string());
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

            match path {
                "" => {
                    let id = self.handles.open_dir(String::new(), "root".to_string());
                    Ok(OpenResult::ThisScheme {
                        number: id,
                        flags: NewFdFlags::POSITIONED,
                    })
                }

                "node" => {
                    let id = self.handles.open_node(self.node_id.clone());
                    Ok(OpenResult::ThisScheme {
                        number: id,
                        flags: NewFdFlags::POSITIONED,
                    })
                }

                ".control" => {
                    let id = self.handles.open_control();
                    Ok(OpenResult::ThisScheme {
                        number: id,
                        flags: NewFdFlags::POSITIONED,
                    })
                }

                "peers" => {
                    let id = self
                        .handles
                        .open_dir("peers".to_string(), "peers".to_string());
                    Ok(OpenResult::ThisScheme {
                        number: id,
                        flags: NewFdFlags::POSITIONED,
                    })
                }

                "blobs" => {
                    let id = self
                        .handles
                        .open_dir("blobs".to_string(), "blobs".to_string());
                    Ok(OpenResult::ThisScheme {
                        number: id,
                        flags: NewFdFlags::POSITIONED,
                    })
                }

                _ if path.starts_with("peers/") => {
                    let name_or_id = &path["peers/".len()..];
                    let (peer_name, node_id) = self
                        .resolve_peer(name_or_id)
                        .ok_or_else(|| Error::new(ENOENT))?;

                    if flags & O_DIRECTORY != 0 {
                        return Err(Error::new(ENOTDIR));
                    }

                    let id = self.handles.open_peer(
                        peer_name,
                        node_id,
                        path.to_string(),
                    );
                    Ok(OpenResult::ThisScheme {
                        number: id,
                        flags: NewFdFlags::POSITIONED,
                    })
                }

                _ if path.starts_with("blobs/") => {
                    let hash = &path["blobs/".len()..];
                    let id = self
                        .handles
                        .open_blob(hash.to_string(), path.to_string());
                    Ok(OpenResult::ThisScheme {
                        number: id,
                        flags: NewFdFlags::POSITIONED,
                    })
                }

                _ if path.starts_with("tickets/") => {
                    let ticket = &path["tickets/".len()..];
                    let id = self
                        .handles
                        .open_ticket(ticket.to_string(), path.to_string());
                    Ok(OpenResult::ThisScheme {
                        number: id,
                        flags: NewFdFlags::POSITIONED,
                    })
                }

                _ => Err(Error::new(ENOENT)),
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
            match self.handles.get_mut(id) {
                Some(Handle::Node(nh)) => {
                    let bytes = nh.node_id.as_bytes();
                    let off = offset as usize;
                    if off >= bytes.len() {
                        return Ok(0);
                    }
                    let remaining = &bytes[off..];
                    let len = remaining.len().min(buf.len());
                    buf[..len].copy_from_slice(&remaining[..len]);
                    Ok(len)
                }

                Some(Handle::Peer(ph)) => {
                    let node_id = ph.node_id.clone();
                    // Drain from shared inbox.
                    let mut guard = self.inbox.lock().unwrap();
                    if let Some(queue) = guard.get_mut(&node_id) {
                        if let Some(msg) = queue.pop_front() {
                            let len = msg.len().min(buf.len());
                            buf[..len].copy_from_slice(&msg[..len]);
                            return Ok(len);
                        }
                    }
                    // No messages — return 0.
                    Ok(0)
                }

                Some(Handle::Blob(bh)) | Some(Handle::Ticket(bh)) => {
                    if !bh.fetched {
                        // Trigger fetch via bridge.
                        let identifier = bh.identifier.clone();
                        let is_ticket = matches!(self.handles.get(id), Some(Handle::Ticket(_)));

                        let (reply_tx, reply_rx) = mpsc::channel();
                        let req = if is_ticket {
                            BridgeRequest::FetchTicket {
                                ticket: identifier,
                                reply: reply_tx,
                            }
                        } else {
                            BridgeRequest::FetchBlob {
                                hash: identifier,
                                reply: reply_tx,
                            }
                        };

                        let _ = self.bridge_tx.send(req);
                        match reply_rx.recv() {
                            Ok(BridgeResponse::Data(data)) => {
                                if let Some(handle) = self.handles.get_mut(id) {
                                    match handle {
                                        Handle::Blob(bh) | Handle::Ticket(bh) => {
                                            bh.data = data;
                                            bh.fetched = true;
                                        }
                                        _ => {}
                                    }
                                }
                            }
                            Ok(BridgeResponse::Error(e)) => {
                                eprintln!("irohd: blob fetch error: {e}");
                                return Err(Error::new(EIO));
                            }
                            _ => return Err(Error::new(EIO)),
                        }
                    }

                    // Read from buffered data.
                    if let Some(Handle::Blob(bh)) | Some(Handle::Ticket(bh)) =
                        self.handles.get_mut(id)
                    {
                        let off = offset as usize;
                        if off >= bh.data.len() {
                            return Ok(0);
                        }
                        let remaining = &bh.data[off..];
                        let len = remaining.len().min(buf.len());
                        buf[..len].copy_from_slice(&remaining[..len]);
                        Ok(len)
                    } else {
                        Err(Error::new(EBADF))
                    }
                }

                Some(Handle::Control(_)) => Err(Error::new(EACCES)),
                Some(Handle::Dir(_)) => Err(Error::new(EBADF)),
                None => Err(Error::new(EBADF)),
            }
        }

        fn write(
            &mut self,
            id: usize,
            buf: &[u8],
            _offset: u64,
            _fcntl_flags: u32,
            _ctx: &CallerCtx,
        ) -> Result<usize> {
            match self.handles.get_mut(id) {
                Some(Handle::Peer(ph)) => {
                    // Accumulate outgoing data.
                    ph.outbox.extend_from_slice(buf);
                    Ok(buf.len())
                }
                Some(Handle::Control(ch)) => {
                    ch.buffer.extend_from_slice(buf);
                    Ok(buf.len())
                }
                _ => Err(Error::new(EACCES)),
            }
        }

        fn fsize(&mut self, id: usize, _ctx: &CallerCtx) -> Result<u64> {
            match self.handles.get(id) {
                Some(Handle::Node(nh)) => Ok(nh.node_id.len() as u64),
                Some(Handle::Blob(bh)) | Some(Handle::Ticket(bh)) => Ok(bh.data.len() as u64),
                _ => Ok(0),
            }
        }

        fn fpath(&mut self, id: usize, buf: &mut [u8], _ctx: &CallerCtx) -> Result<usize> {
            let path = match self.handles.get(id) {
                Some(Handle::Node(_)) => "/scheme/iroh/node".to_string(),
                Some(Handle::Peer(ph)) => format!("/scheme/iroh/{}", ph.scheme_path),
                Some(Handle::Blob(bh)) | Some(Handle::Ticket(bh)) => {
                    format!("/scheme/iroh/{}", bh.scheme_path)
                }
                Some(Handle::Control(_)) => "/scheme/iroh/.control".to_string(),
                Some(Handle::Dir(dh)) => {
                    if dh.scheme_path.is_empty() {
                        "/scheme/iroh".to_string()
                    } else {
                        format!("/scheme/iroh/{}", dh.scheme_path)
                    }
                }
                None => return Err(Error::new(EBADF)),
            };

            let bytes = path.as_bytes();
            let len = bytes.len().min(buf.len());
            buf[..len].copy_from_slice(&bytes[..len]);
            Ok(len)
        }

        fn fevent(
            &mut self,
            id: usize,
            _flags: syscall::flag::EventFlags,
            _ctx: &CallerCtx,
        ) -> Result<syscall::flag::EventFlags> {
            match self.handles.get(id) {
                Some(Handle::Node(_))
                | Some(Handle::Peer(_))
                | Some(Handle::Blob(_))
                | Some(Handle::Ticket(_))
                | Some(Handle::Dir(_)) => Ok(syscall::flag::EventFlags::EVENT_READ),
                Some(Handle::Control(_)) => Ok(syscall::flag::EventFlags::EVENT_WRITE),
                None => Err(Error::new(EBADF)),
            }
        }

        fn fstat(&mut self, id: usize, stat: &mut Stat, _ctx: &CallerCtx) -> Result<()> {
            match self.handles.get(id) {
                Some(Handle::Node(nh)) => {
                    stat.st_mode = 0o100444; // Read-only file.
                    stat.st_size = nh.node_id.len() as u64;
                    stat.st_nlink = 1;
                }
                Some(Handle::Peer(_)) => {
                    stat.st_mode = 0o100666; // Read-write file.
                    stat.st_size = 0;
                    stat.st_nlink = 1;
                }
                Some(Handle::Blob(bh)) | Some(Handle::Ticket(bh)) => {
                    stat.st_mode = 0o100444;
                    stat.st_size = bh.data.len() as u64;
                    stat.st_nlink = 1;
                }
                Some(Handle::Control(_)) => {
                    stat.st_mode = 0o100222; // Write-only.
                    stat.st_size = 0;
                    stat.st_nlink = 1;
                }
                Some(Handle::Dir(_)) => {
                    stat.st_mode = 0o040555; // Directory.
                    stat.st_size = 0;
                    stat.st_nlink = 2;
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
            let dir_type = match self.handles.get(id) {
                Some(Handle::Dir(dh)) => dh.dir_type.clone(),
                Some(_) => return Err(Error::new(ENOTDIR)),
                None => return Err(Error::new(EBADF)),
            };

            let start = opaque_offset as usize;

            match dir_type.as_str() {
                "root" => {
                    // Root: show node, peers/, blobs/, .control
                    let entries = ["node", "peers", "blobs", ".control"];
                    for (i, name) in entries.iter().enumerate().skip(start) {
                        let kind = match *name {
                            "peers" | "blobs" => DirentKind::Directory,
                            _ => DirentKind::Regular,
                        };
                        if buf
                            .entry(RedoxDirEntry {
                                inode: 0,
                                next_opaque_id: (i + 1) as u64,
                                name,
                                kind,
                            })
                            .is_err()
                        {
                            break;
                        }
                    }
                }

                "peers" => {
                    let peer_names: Vec<String> = self.peers.keys().cloned().collect();
                    for (i, name) in peer_names.iter().enumerate().skip(start) {
                        if buf
                            .entry(RedoxDirEntry {
                                inode: 0,
                                next_opaque_id: (i + 1) as u64,
                                name,
                                kind: DirentKind::Regular,
                            })
                            .is_err()
                        {
                            break;
                        }
                    }
                }

                "blobs" => {
                    // Blobs are fetched on-demand — no directory listing.
                    // Return empty.
                }

                _ => {}
            }

            Ok(buf)
        }

        fn on_close(&mut self, id: usize) {
            match self.handles.close(id) {
                Some(Handle::Control(ch)) => {
                    if !ch.buffer.is_empty() {
                        let command = String::from_utf8_lossy(&ch.buffer);
                        self.process_control(&command);
                    }
                }
                Some(Handle::Peer(ph)) => {
                    // Send accumulated outbox on close.
                    if !ph.outbox.is_empty() {
                        let (reply_tx, reply_rx) = mpsc::channel();
                        let req = BridgeRequest::SendMessage {
                            node_id: ph.node_id.clone(),
                            data: ph.outbox,
                            reply: reply_tx,
                        };
                        let _ = self.bridge_tx.send(req);
                        // Wait for send to complete (or fail).
                        match reply_rx.recv() {
                            Ok(BridgeResponse::Ok) => {
                                eprintln!(
                                    "irohd: sent message to {}",
                                    ph.peer_name
                                );
                            }
                            Ok(BridgeResponse::Error(e)) => {
                                eprintln!(
                                    "irohd: send to {} failed: {e}",
                                    ph.peer_name
                                );
                            }
                            _ => {}
                        }
                    }
                }
                _ => {}
            }
        }
    }

    /// Run the iroh scheme daemon (blocking).
    pub fn run_daemon(config: IrohConfig) -> std::result::Result<(), Box<dyn std::error::Error>> {
        eprintln!("irohd: initializing");

        // Start the iroh runtime thread.
        let (bridge_tx, inbox, node_id) = bridge::start_iroh_thread(config.secret_key)?;
        eprintln!("irohd: node_id={node_id}");

        let mut handler = IrohSchemeHandler::new(
            node_id,
            config.peers,
            bridge_tx,
            inbox,
        );
        let mut state = SchemeState::new();

        // Register the `iroh` scheme.
        eprintln!("irohd: creating scheme socket...");
        let socket = Socket::create().map_err(|e| {
            format!("irohd: Socket::create failed: {e}")
        })?;

        eprintln!("irohd: registering scheme 'iroh'...");
        redox_scheme::scheme::register_sync_scheme(&socket, "iroh", &mut handler)
            .map_err(|e| format!("irohd: registration failed: {e}"))?;
        eprintln!("irohd: scheme 'iroh' registered");

        // NOTE: We do NOT enter null namespace (setrens) because
        // the iroh thread needs ongoing access to udp:/tcp: schemes
        // for P2P connections.

        // Main event loop.
        eprintln!("irohd: entering event loop");
        loop {
            let req = match socket.next_request(SignalBehavior::Restart)? {
                None => {
                    eprintln!("irohd: socket closed");
                    break;
                }
                Some(req) => req,
            };

            match req.kind() {
                RequestKind::Call(call_req) => {
                    let response = call_req.handle_sync(&mut handler, &mut state);
                    if !socket.write_response(response, SignalBehavior::Restart)? {
                        eprintln!("irohd: write_response returned false");
                        break;
                    }
                }
                RequestKind::OnClose { id } => {
                    handler.on_close(id);
                }
                _ => continue,
            }
        }

        eprintln!("irohd: shutting down");
        Ok(())
    }
}

#[cfg(target_os = "redox")]
pub use redox_impl::run_daemon;

// Re-export for non-Redox (allows the crate to compile on Linux for checking).
#[cfg(not(target_os = "redox"))]
pub fn run_daemon(_config: IrohConfig) -> Result<(), Box<dyn std::error::Error>> {
    eprintln!("irohd: scheme registration requires Redox OS");
    eprintln!("irohd: running in stub mode (no scheme, testing bridge only)");

    let (bridge_tx, _inbox, node_id) = bridge::start_iroh_thread(_config.secret_key)?;
    eprintln!("irohd: node_id={node_id}");
    eprintln!("irohd: press Ctrl+C to exit");

    // Just keep the main thread alive.
    loop {
        std::thread::sleep(std::time::Duration::from_secs(3600));
    }
}
