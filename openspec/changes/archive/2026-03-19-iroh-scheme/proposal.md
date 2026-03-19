## Why

Redox has TCP/UDP networking via smolnetd schemes, but no P2P networking primitive. iroh provides QUIC-based peer-to-peer connections with content-addressed blob transfer, relay fallback, and hole-punching. Exposing iroh as a Redox scheme lets any program do P2P communication through ordinary file operations — no special libraries, just open/read/write.

## What Changes

- New `iroh:` userspace scheme daemon (`irohd`) providing P2P networking as file operations
- `iroh:node` — read returns this node's endpoint ID
- `iroh:peers/` — directory listing of known/connected peers
- `iroh:peers/<name_or_id>` — read receives messages, write sends messages
- `iroh:blobs/<hash>` — read fetches content-addressed data from the network
- `iroh:tickets/<ticket>` — read fetches blob by ticket (includes peer routing info)
- `iroh:.control` — JSON command interface for adding peers, importing blobs
- New Nix package for `irohd` with cross-compilation support
- Init script integration for starting `irohd` during boot

## Capabilities

### New Capabilities
- `iroh-scheme`: P2P networking scheme daemon exposing iroh's QUIC transport, peer messaging, and content-addressed blob transfer through Redox file operations

### Modified Capabilities

(none — this is purely additive)

## Impact

- New daemon binary: `irohd` (Rust, depends on `iroh`, `redox_scheme`, `tokio`)
- Network access: needs `udp:` and `tcp:` schemes from smolnetd for QUIC transport and relay connections
- Init system: new init script entry to start `irohd` after networking is up
- Disk: node secret key persisted to maintain stable identity across reboots
- No changes to existing schemes or kernel
