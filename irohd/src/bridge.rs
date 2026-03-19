//! Async runtime bridge between the synchronous scheme handler
//! and the tokio-based iroh endpoint.
//!
//! The scheme thread sends requests over an mpsc channel.
//! The iroh thread processes them asynchronously and sends
//! responses back on a per-request oneshot-style channel.

use std::collections::{HashMap, VecDeque};
use std::sync::{mpsc, Arc, Mutex};

/// Request from scheme thread → iroh thread.
pub enum BridgeRequest {
    /// Send a message to a peer.
    SendMessage {
        node_id: String,
        data: Vec<u8>,
        reply: mpsc::Sender<BridgeResponse>,
    },
    /// Fetch a blob by hash.
    FetchBlob {
        hash: String,
        reply: mpsc::Sender<BridgeResponse>,
    },
    /// Fetch a blob by ticket.
    FetchTicket {
        ticket: String,
        reply: mpsc::Sender<BridgeResponse>,
    },
    /// Get node ID.
    GetNodeId {
        reply: mpsc::Sender<BridgeResponse>,
    },
    /// Drain messages from a peer's inbox.
    DrainInbox {
        node_id: String,
        reply: mpsc::Sender<BridgeResponse>,
    },
    /// Shutdown the iroh thread.
    Shutdown,
}

/// Response from iroh thread → scheme thread.
pub enum BridgeResponse {
    /// Operation succeeded.
    Ok,
    /// Operation returned data.
    Data(Vec<u8>),
    /// Node ID string.
    NodeId(String),
    /// Messages from a peer.
    Messages(VecDeque<Vec<u8>>),
    /// Operation failed.
    Error(String),
}

/// Shared inbox for incoming peer messages.
/// The iroh accept loop pushes messages here;
/// the scheme handler drains them on read().
pub type SharedInbox = Arc<Mutex<HashMap<String, VecDeque<Vec<u8>>>>>;

/// Start the iroh runtime on a background thread.
///
/// Returns:
/// - Sender for bridge requests
/// - Shared inbox for incoming messages
/// - Node ID string
pub fn start_iroh_thread(
    secret_key_bytes: [u8; 32],
) -> Result<(mpsc::Sender<BridgeRequest>, SharedInbox, String), Box<dyn std::error::Error>> {
    let (tx, rx) = mpsc::channel::<BridgeRequest>();
    let inbox: SharedInbox = Arc::new(Mutex::new(HashMap::new()));
    let inbox_clone = inbox.clone();

    // Channel to receive the node ID after endpoint creation.
    let (node_id_tx, node_id_rx) = mpsc::channel::<Result<String, String>>();

    std::thread::Builder::new()
        .name("iroh-runtime".into())
        .spawn(move || {
            let rt = match tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
            {
                Ok(rt) => rt,
                Err(e) => {
                    let _ = node_id_tx.send(Err(format!("tokio runtime: {e}")));
                    return;
                }
            };

            rt.block_on(async move {
                match run_iroh(secret_key_bytes, rx, inbox_clone, node_id_tx).await {
                    Ok(()) => eprintln!("irohd: iroh thread exiting cleanly"),
                    Err(e) => eprintln!("irohd: iroh thread error: {e}"),
                }
            });
        })?;

    // Wait for the node ID from the iroh thread.
    let node_id = node_id_rx
        .recv()
        .map_err(|e| format!("iroh thread died during init: {e}"))?
        .map_err(|e| format!("iroh endpoint init failed: {e}"))?;

    Ok((tx, inbox, node_id))
}

/// ALPN protocol identifier for irohd messaging.
const IROHD_ALPN: &[u8] = b"irohd/msg/0";

/// Main async loop running on the iroh thread.
async fn run_iroh(
    secret_key_bytes: [u8; 32],
    rx: mpsc::Receiver<BridgeRequest>,
    inbox: SharedInbox,
    node_id_tx: mpsc::Sender<Result<String, String>>,
) -> Result<(), Box<dyn std::error::Error>> {
    use iroh::SecretKey;

    // Create the iroh endpoint.
    let secret_key = SecretKey::from_bytes(&secret_key_bytes);
    let endpoint = match iroh::Endpoint::builder()
        .secret_key(secret_key)
        .alpns(vec![IROHD_ALPN.to_vec()])
        .bind()
        .await
    {
        Ok(ep) => {
            let node_id = ep.node_id().to_string();
            let _ = node_id_tx.send(Ok(node_id));
            ep
        }
        Err(e) => {
            let _ = node_id_tx.send(Err(e.to_string()));
            return Err(e.into());
        }
    };

    eprintln!("irohd: endpoint bound, node_id={}", endpoint.node_id());

    // Spawn the accept loop for incoming connections.
    let ep_accept = endpoint.clone();
    let inbox_accept = inbox.clone();
    tokio::spawn(async move {
        accept_loop(ep_accept, inbox_accept).await;
    });

    // Process bridge requests.
    loop {
        // Use try_recv in a loop with a small sleep to avoid blocking
        // the async runtime. A proper solution would use tokio::sync::mpsc
        // but std::sync::mpsc is what the scheme thread can use.
        let req = match rx.recv() {
            Ok(r) => r,
            Err(_) => {
                eprintln!("irohd: bridge channel closed, shutting down");
                break;
            }
        };

        match req {
            BridgeRequest::GetNodeId { reply } => {
                let _ = reply.send(BridgeResponse::NodeId(endpoint.node_id().to_string()));
            }
            BridgeRequest::SendMessage {
                node_id,
                data,
                reply,
            } => {
                let ep = endpoint.clone();
                let resp = send_message(&ep, &node_id, data).await;
                let _ = reply.send(resp);
            }
            BridgeRequest::FetchBlob { hash, reply } => {
                // Blob fetching requires iroh-blobs which is a separate crate.
                // For now, return an error indicating blobs aren't implemented yet.
                let _ = reply.send(BridgeResponse::Error(
                    "blob fetch not yet implemented".into(),
                ));
                let _ = hash;
            }
            BridgeRequest::FetchTicket { ticket, reply } => {
                let _ = reply.send(BridgeResponse::Error(
                    "ticket fetch not yet implemented".into(),
                ));
                let _ = ticket;
            }
            BridgeRequest::DrainInbox { node_id, reply } => {
                let mut guard = inbox.lock().unwrap();
                let msgs = guard
                    .get_mut(&node_id)
                    .map(|q| std::mem::take(q))
                    .unwrap_or_default();
                let _ = reply.send(BridgeResponse::Messages(msgs));
            }
            BridgeRequest::Shutdown => {
                eprintln!("irohd: shutdown requested");
                break;
            }
        }
    }

    endpoint.close().await;
    Ok(())
}

/// Accept incoming connections and buffer messages per peer.
async fn accept_loop(endpoint: iroh::Endpoint, inbox: SharedInbox) {
    loop {
        let incoming = match endpoint.accept().await {
            Some(inc) => inc,
            None => {
                eprintln!("irohd: accept loop ended (endpoint closed)");
                break;
            }
        };

        let inbox = inbox.clone();
        tokio::spawn(async move {
            match incoming.await {
                Ok(conn) => {
                    let peer_id = conn.remote_node_id()
                        .map(|id| id.to_string())
                        .unwrap_or_else(|_| "unknown".to_string());

                    // Accept bidirectional streams on this connection.
                    while let Ok((mut send, mut recv)) = conn.accept_bi().await {
                        let mut buf = Vec::new();
                        // Read the full message.
                        match recv.read_to_end(1024 * 1024).await {
                            Ok(data) => {
                                buf = data.to_vec();
                            }
                            Err(e) => {
                                eprintln!("irohd: recv from {peer_id}: {e}");
                                continue;
                            }
                        }

                        if !buf.is_empty() {
                            eprintln!(
                                "irohd: received {} bytes from {peer_id}",
                                buf.len()
                            );
                            let mut guard = inbox.lock().unwrap();
                            guard
                                .entry(peer_id.clone())
                                .or_insert_with(VecDeque::new)
                                .push_back(buf);
                        }

                        // Send an ack.
                        let _ = send.write_all(b"ok").await;
                        let _ = send.finish();
                    }
                }
                Err(e) => {
                    eprintln!("irohd: incoming connection failed: {e}");
                }
            }
        });
    }
}

/// Send a message to a peer by node ID.
async fn send_message(
    endpoint: &iroh::Endpoint,
    node_id_hex: &str,
    data: Vec<u8>,
) -> BridgeResponse {
    use std::str::FromStr;

    let node_id = match iroh::NodeId::from_str(node_id_hex) {
        Ok(id) => id,
        Err(e) => return BridgeResponse::Error(format!("invalid node ID: {e}")),
    };

    let conn = match endpoint.connect(node_id, IROHD_ALPN).await {
        Ok(c) => c,
        Err(e) => return BridgeResponse::Error(format!("connect to {node_id_hex}: {e}")),
    };

    match conn.open_bi().await {
        Ok((mut send, mut recv)) => {
            if let Err(e) = send.write_all(&data).await {
                return BridgeResponse::Error(format!("send: {e}"));
            }
            if let Err(e) = send.finish() {
                return BridgeResponse::Error(format!("finish: {e}"));
            }
            // Wait for ack.
            let _ = recv.read_to_end(64).await;
            BridgeResponse::Ok
        }
        Err(e) => BridgeResponse::Error(format!("open stream: {e}")),
    }
}
