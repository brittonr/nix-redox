//! Handle table for iroh scheme resources.

#![cfg_attr(not(target_os = "redox"), allow(dead_code))]

use std::collections::{HashMap, VecDeque};

/// Handle types for the iroh scheme.
pub enum Handle {
    /// `iroh:node` — read returns the endpoint ID.
    Node(NodeHandle),
    /// `iroh:peers/<name>` — messaging handle.
    Peer(PeerHandle),
    /// `iroh:blobs/<hash>` — content-addressed blob read.
    Blob(BlobHandle),
    /// `iroh:tickets/<ticket>` — blob fetch by ticket.
    Ticket(BlobHandle),
    /// `iroh:.control` — JSON command buffer.
    Control(ControlHandle),
    /// Directory listing handle.
    Dir(DirHandle),
}

pub struct NodeHandle {
    /// The endpoint ID string (hex-encoded).
    pub node_id: String,
    /// Read cursor.
    pub offset: usize,
}

pub struct PeerHandle {
    /// Peer name (human-readable).
    pub peer_name: String,
    /// Peer node ID (hex).
    pub node_id: String,
    /// Buffered incoming messages.
    pub inbox: VecDeque<Vec<u8>>,
    /// Bytes written (outgoing message accumulator).
    pub outbox: Vec<u8>,
    /// Scheme-relative path for fpath.
    pub scheme_path: String,
}

pub struct BlobHandle {
    /// Hash or ticket string used to open this handle.
    pub identifier: String,
    /// Downloaded data (populated by iroh thread).
    pub data: Vec<u8>,
    /// Whether the fetch has completed.
    pub fetched: bool,
    /// Read cursor.
    pub offset: usize,
    /// Scheme-relative path for fpath.
    pub scheme_path: String,
}

pub struct ControlHandle {
    /// Accumulated write buffer (JSON command).
    pub buffer: Vec<u8>,
}

pub struct DirHandle {
    /// Scheme-relative path.
    pub scheme_path: String,
    /// Which directory: "peers", "blobs", "" (root).
    pub dir_type: String,
}

/// Handle table with auto-incrementing IDs.
pub struct HandleTable {
    handles: HashMap<usize, Handle>,
    next_id: usize,
}

impl HandleTable {
    pub fn new() -> Self {
        Self {
            handles: HashMap::new(),
            next_id: 0,
        }
    }

    fn alloc(&mut self, handle: Handle) -> usize {
        let id = self.next_id;
        self.next_id += 1;
        self.handles.insert(id, handle);
        id
    }

    pub fn get(&self, id: usize) -> Option<&Handle> {
        self.handles.get(&id)
    }

    pub fn get_mut(&mut self, id: usize) -> Option<&mut Handle> {
        self.handles.get_mut(&id)
    }

    pub fn close(&mut self, id: usize) -> Option<Handle> {
        self.handles.remove(&id)
    }

    // --- Constructors for each handle type ---

    pub fn open_node(&mut self, node_id: String) -> usize {
        self.alloc(Handle::Node(NodeHandle {
            node_id,
            offset: 0,
        }))
    }

    pub fn open_peer(
        &mut self,
        peer_name: String,
        node_id: String,
        scheme_path: String,
    ) -> usize {
        self.alloc(Handle::Peer(PeerHandle {
            peer_name,
            node_id,
            inbox: VecDeque::new(),
            outbox: Vec::new(),
            scheme_path,
        }))
    }

    pub fn open_blob(&mut self, identifier: String, scheme_path: String) -> usize {
        self.alloc(Handle::Blob(BlobHandle {
            identifier,
            data: Vec::new(),
            fetched: false,
            offset: 0,
            scheme_path,
        }))
    }

    pub fn open_ticket(&mut self, identifier: String, scheme_path: String) -> usize {
        self.alloc(Handle::Ticket(BlobHandle {
            identifier,
            data: Vec::new(),
            fetched: false,
            offset: 0,
            scheme_path,
        }))
    }

    pub fn open_control(&mut self) -> usize {
        self.alloc(Handle::Control(ControlHandle { buffer: Vec::new() }))
    }

    pub fn open_dir(&mut self, scheme_path: String, dir_type: String) -> usize {
        self.alloc(Handle::Dir(DirHandle {
            scheme_path,
            dir_type,
        }))
    }
}
