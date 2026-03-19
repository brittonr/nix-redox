## ADDED Requirements

### Requirement: Scheme registration
The `irohd` daemon SHALL register the `iroh` scheme with the Redox kernel using `redox_scheme::Socket::create()` and `register_sync_scheme()`. The daemon SHALL enter its event loop after registration and process scheme requests until the socket closes.

#### Scenario: Successful startup
- **WHEN** `irohd` starts and smolnetd is running
- **THEN** the `iroh` scheme is accessible at `/scheme/iroh/`

#### Scenario: Startup without network
- **WHEN** `irohd` starts but smolnetd is not running
- **THEN** `irohd` SHALL register the scheme and enter the event loop, but peer connections will fail with I/O errors on read/write

### Requirement: Node identity
The daemon SHALL read a persistent node secret key from a config file at startup. If no key file exists, the daemon SHALL generate a new key and write it. The node's public endpoint ID SHALL be deterministically derived from this key.

#### Scenario: First boot generates key
- **WHEN** `irohd` starts and no key file exists at the configured path
- **THEN** a new iroh `SecretKey` is generated, written to disk, and used for the endpoint

#### Scenario: Subsequent boot reuses key
- **WHEN** `irohd` starts and a key file exists
- **THEN** the key is loaded and the node's endpoint ID matches the previous boot

### Requirement: Read node identity
Opening `iroh:node` for reading SHALL return the node's endpoint ID as a UTF-8 string (hex-encoded public key).

#### Scenario: Read node ID
- **WHEN** a program opens `/scheme/iroh/node` and reads
- **THEN** the read returns the node's endpoint ID as a string

### Requirement: Peer directory listing
Opening `iroh:peers/` with `O_DIRECTORY` SHALL return directory entries for all known peers (from config and runtime-added peers).

#### Scenario: List peers
- **WHEN** a program lists `/scheme/iroh/peers/`
- **THEN** `getdents` returns one entry per known peer, using the peer's human-readable name if configured, otherwise the node ID

### Requirement: Send message to peer
Writing to `iroh:peers/<name_or_id>` SHALL send the written bytes as a message to the identified peer over QUIC.

#### Scenario: Send by name
- **WHEN** a program opens `/scheme/iroh/peers/alice` and writes `"hello"`
- **THEN** the bytes are sent to the peer mapped to name `alice` in the peer table

#### Scenario: Send by node ID
- **WHEN** a program opens `/scheme/iroh/peers/<64-char-hex-id>` and writes data
- **THEN** the bytes are sent to the peer with that node ID

#### Scenario: Send to unknown peer
- **WHEN** a program opens `/scheme/iroh/peers/unknown_name` and the name is not in the peer table
- **THEN** the open returns `ENOENT`

### Requirement: Receive messages from peer
Reading from `iroh:peers/<name_or_id>` SHALL return buffered messages received from that peer. If no messages are buffered, the read SHALL return 0 bytes.

#### Scenario: Read with messages available
- **WHEN** a program reads from `/scheme/iroh/peers/alice` and messages are buffered
- **THEN** the read returns the oldest buffered message and removes it from the buffer

#### Scenario: Read with no messages
- **WHEN** a program reads from `/scheme/iroh/peers/alice` and no messages are buffered
- **THEN** the read returns 0 bytes

### Requirement: Fetch blob by hash
Opening `iroh:blobs/<hash>` for reading SHALL fetch the content-addressed blob from the network. The read SHALL stream the blob contents sequentially.

#### Scenario: Fetch existing blob
- **WHEN** a program opens `/scheme/iroh/blobs/<blake3_hash>` and reads
- **THEN** the read returns the blob data, verified against the hash

#### Scenario: Fetch unavailable blob
- **WHEN** a program opens `/scheme/iroh/blobs/<hash>` and no peer has the blob
- **THEN** the read returns an I/O error (`EIO`)

### Requirement: Fetch blob by ticket
Opening `iroh:tickets/<blob_ticket>` for reading SHALL parse the ticket (which encodes hash + peer info), connect to the peer, and stream the blob contents.

#### Scenario: Fetch by ticket
- **WHEN** a program opens `/scheme/iroh/tickets/<ticket_string>` and reads
- **THEN** the daemon connects to the peer specified in the ticket and returns the blob data

### Requirement: Control interface
Opening `iroh:.control` for writing SHALL accept JSON commands. Commands are processed when the handle is closed (write-then-close pattern, same as `stored` and `profiled`).

#### Scenario: Add peer via control
- **WHEN** a program writes `{"addPeer": {"name": "alice", "id": "<node_id>"}}` to `/scheme/iroh/.control` and closes
- **THEN** the peer is added to the runtime peer table and `iroh:peers/alice` becomes accessible

#### Scenario: Remove peer via control
- **WHEN** a program writes `{"removePeer": {"name": "alice"}}` to `/scheme/iroh/.control` and closes
- **THEN** the peer is removed from the runtime peer table

### Requirement: Async runtime bridge
The daemon SHALL run the iroh endpoint on a background thread with a tokio runtime. The scheme handler SHALL communicate with the iroh thread via channels. Scheme operations SHALL NOT block the event loop waiting for network I/O beyond the channel round-trip.

#### Scenario: Concurrent scheme requests during network operation
- **WHEN** a blob fetch is in progress on the iroh thread and a new scheme request arrives
- **THEN** the new request is processed without waiting for the blob fetch to complete

### Requirement: Init script integration
The daemon SHALL be startable via an init script that runs after networking (smolnetd) is available. The init script SHALL use the `daemon` type so the parent can continue after irohd signals readiness.

#### Scenario: Boot ordering
- **WHEN** the system boots with irohd enabled
- **THEN** irohd starts after smolnetd and before the user shell
