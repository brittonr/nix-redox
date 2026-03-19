## 1. Investigate iroh on Redox feasibility

- [x] 1.1 Check iroh's dependency tree for mio/tokio Redox compatibility — determine if mio has a Redox backend or if an adapter is needed
- [x] 1.2 Try cross-compiling a minimal iroh endpoint binary for x86_64-unknown-redox to identify build failures early
- [x] 1.3 Document any relibc patches or shims needed for iroh's networking stack

## 2. Crate and project setup

- [x] 2.1 Create `irohd` crate directory under `nix/pkgs/system/irohd/` with Cargo.toml, src/main.rs
- [x] 2.2 Add dependencies: `iroh`, `redox_scheme`, `syscall`, `libredox`, `serde`, `serde_json`, `tokio` (rt-multi-thread)
- [x] 2.3 Add Nix package definition for irohd with cross-compilation support
- [x] 2.4 Vendor iroh dependencies and compute vendor hash

## 3. Node identity

- [x] 3.1 Implement key file load/generate — read `/etc/iroh/node.key`, generate if absent
- [x] 3.2 Create iroh `Endpoint` from the loaded secret key
- [x] 3.3 Implement `iroh:node` read handler returning the endpoint ID as hex string

## 4. Async runtime bridge

- [x] 4.1 Spawn a background thread running `tokio::runtime::Runtime` with the iroh endpoint
- [x] 4.2 Define request/response enums for the channel protocol (Connect, Send, FetchBlob, ListPeers, etc.)
- [x] 4.3 Implement the channel bridge — scheme thread sends requests via `mpsc::Sender`, blocks on `mpsc::Receiver` for response
- [x] 4.4 Implement the iroh thread's request dispatch loop

## 5. Scheme handler — core

- [x] 5.1 Implement `SchemeSync` trait for `IrohSchemeHandler` — `scheme_root`, `openat`, `read`, `write`, `fstat`, `fpath`, `getdents`, `on_close`
- [x] 5.2 Define handle types: `Node`, `Peer`, `Blob`, `Ticket`, `Control`, `Dir`
- [x] 5.3 Implement path parsing — route `node`, `peers/*`, `blobs/*`, `tickets/*`, `.control` to correct handle types
- [x] 5.4 Implement `run_daemon()` — socket create, scheme register, event loop

## 6. Peer management

- [x] 6.1 Load peers from `/etc/iroh/peers.json` at startup (name → node ID mapping)
- [x] 6.2 Implement `.control` addPeer/removePeer JSON commands
- [x] 6.3 Implement `iroh:peers/` directory listing from peer table
- [x] 6.4 Implement peer name → node ID resolution in openat

## 7. Peer messaging

- [x] 7.1 Implement write handler for peer handles — send bytes to iroh thread for delivery
- [x] 7.2 Implement message receive on iroh thread — accept incoming connections, buffer messages per peer
- [x] 7.3 Implement read handler for peer handles — drain from per-peer inbox, return 0 when empty
- [x] 7.4 Wire up ALPN protocol identifier for iroh messaging

## 8. Blob fetch

- [x] 8.1 Implement blob hash parsing in openat for `blobs/<hash>` paths
- [x] 8.2 Implement blob fetch request to iroh thread — download blob, buffer chunks
- [x] 8.3 Implement streaming read for blob handles — cursor tracking, sequential chunk delivery
- [x] 8.4 Implement ticket parsing in openat for `tickets/<ticket>` paths
- [x] 8.5 Implement ticket-based blob fetch (extract peer + hash from ticket, connect and download)

## 9. Init and packaging

- [x] 9.1 Create init script entry for irohd (after smolnetd, daemon type)
- [x] 9.2 Add irohd to a module/profile (e.g., `networking.nix` or new `iroh.nix` module)
- [x] 9.3 Create default `/etc/iroh/peers.json` (empty) in disk image

## 10. Testing

- [x] 10.1 Build irohd and boot a VM image with it — verify scheme registration in boot log
- [x] 10.2 Test `cat /scheme/iroh/node` returns a valid endpoint ID
- [x] 10.3 Test peer messaging between two VMs or loopback (add self as peer, send/recv)
- [x] 10.4 Test `.control` addPeer command
- [x] 10.5 Test `ls /scheme/iroh/peers/` shows configured peers
