## Context

Redox exposes all I/O through schemes — userspace daemons that register with the kernel and handle file operations. Network schemes (`tcp:`, `udp:`) already exist via smolnetd. This design adds `iroh:` for P2P QUIC networking following the same pattern.

The existing scheme daemons (`stored`, `profiled`) use `redox_scheme`'s `SchemeSync` trait with a synchronous event loop. iroh is async (tokio-based). The core architectural challenge is bridging async iroh operations into the synchronous scheme handler.

## Goals / Non-Goals

**Goals:**
- P2P messaging between Redox nodes via file read/write
- Content-addressed blob fetch via file read
- Stable node identity persisted across reboots
- Works from Ion shell with no special tooling

**Non-Goals:**
- Blob publishing/hosting (read-only fetch for now — import/share is future work)
- Discovery protocols (DNS-SD, DHT) — peers are added manually via `.control`
- Relay server hosting — uses public iroh relays only
- Multi-scheme split (`iroh.blob:`, `iroh.msg:`) — single `iroh:` scheme keeps it simple

## Decisions

### 1. Two-thread architecture: sync scheme + async iroh runtime

The scheme handler runs on the main thread (synchronous, processes kernel packets). A second thread runs a tokio runtime with the iroh endpoint. Communication via `std::sync::mpsc` channels.

**Why not single-threaded async?** `SchemeSync` is synchronous — the `redox_scheme` crate's event loop calls trait methods that must return values immediately. We can't `.await` inside them. A background runtime thread is the established escape hatch (same pattern as `FileIoWorker` in `stored`).

**Why not `crossbeam`?** `std::sync::mpsc` is sufficient. The scheme thread sends requests and blocks on a `Receiver` for the response. One request at a time (scheme event loop is single-threaded), so no complex multiplexing needed.

### 2. Peer messaging as buffered inboxes

Each peer handle has an inbox (`VecDeque<Vec<u8>>`). The iroh runtime thread receives messages and pushes them into the inbox. The scheme handler's `read()` drains from the inbox.

When the inbox is empty, `read()` returns 0 bytes (EOF-like). Programs that want blocking reads re-open and retry — or we use `fevent` with `EVENT_READ` to notify when messages arrive.

**Why not true blocking reads?** Blocking in the scheme handler blocks ALL scheme requests. Non-blocking reads with event notification is the Redox-idiomatic approach (same as `tcp:` scheme).

### 3. Pre-open network schemes, defer setrens

iroh needs to open new UDP sockets dynamically (for hole-punching, relay connections). This conflicts with `setrens(0, 0)` which prevents new scheme opens.

**Decision:** Don't enter null namespace. Instead, run with restricted permissions but keep scheme access. This is the same approach `sudo` daemon takes — it needs ongoing access to `proc:` scheme.

**Alternative considered:** Pre-open a pool of UDP sockets. Rejected because iroh's connection logic manages its own sockets internally, and we can't predict how many it needs.

### 4. Node identity from pre-generated key file

The iroh `SecretKey` is read from `/etc/iroh/node.key` at startup. If absent, generate one and write it. This gives stable node IDs across reboots.

**Why not generate at build time?** Nix builds are pure — random key generation would break reproducibility. Generate on first boot instead.

### 5. Blob fetch is streaming, not buffered

When a program reads `iroh:blobs/<hash>`, the scheme handler sends a fetch request to the iroh thread. Data arrives in chunks. A `BlobHandle` tracks the read cursor and buffers the current chunk. Sequential reads stream through without loading the entire blob into memory.

**Why not memory-map?** `fmap` would be ideal but requires the blob to be fully downloaded first. Streaming reads work for arbitrary blob sizes.

### 6. Peer names via config file, not DNS

Peers are identified by iroh node IDs (public keys). Human-readable names map to IDs via `/etc/iroh/peers.json` (loaded at startup) and `.control` commands at runtime.

Opening `iroh:peers/<name>` looks up the name in the peer table. Opening `iroh:peers/<node_id>` works directly. Unknown names return ENOENT.

## Risks / Trade-offs

- **[Network dependency]** iroh needs UDP and TCP access. If smolnetd isn't running or network is down, the iroh endpoint can't connect. → Mitigation: irohd starts after smolnetd in init ordering; connection failures surface as read/write errors on handles.
- **[No null namespace]** Skipping setrens means irohd has broader system access than stored/profiled. → Mitigation: irohd only needs network schemes, not file:. Could use a restricted namespace that includes only udp:/tcp:/ip: if namespace filtering is available.
- **[Async/sync bridge latency]** Channel round-trip adds latency vs. direct async. → Mitigation: messaging is already network-bound; channel overhead is negligible compared to QUIC round-trips.
- **[iroh crate size]** iroh pulls in tokio, quinn, rustls — large dependency tree. → Mitigation: cross-compile on host, only the final binary goes on disk. iroh is ~5MB stripped.
- **[relibc compatibility]** iroh uses mio/tokio which need epoll/kqueue. Redox has event: scheme but mio might not have a Redox backend. → Mitigation: may need a mio adapter or use iroh's sync API if available. This is the highest-risk item and needs investigation during implementation.
