## Why

Our `pathinfo::PathInfo` stores metadata as raw strings (`store_path: String`, `nar_hash: String`, `references: Vec<String>`, `signatures: Vec<String>`). Upstream snix uses typed wrappers (`StorePath<String>`, `[u8; 32]`, `Signature<String>`). This type mismatch blocks interop with upstream services — we can't call `PathInfoService::put()`, parse narinfo into our type, or use upstream's signature verification without manual conversion at every boundary.

Replacing our type wholesale isn't practical: upstream's `PathInfo` has a mandatory `node: Node` field (castore content address) that we don't produce yet, and we have extra fields (`registration_time`, `files`) that upstream doesn't carry. A 126-call-site migration for a type that doesn't fully fit isn't worth it.

Instead, add bidirectional conversion between our type and upstream's. This lets code that talks to upstream services convert at the boundary, while internal code keeps using our type unchanged.

## What Changes

- Add `impl From<&PathInfo> for snix_store::path_info::PathInfo` (our → upstream) using a dummy castore Node
- Add `impl TryFrom<&snix_store::path_info::PathInfo> for PathInfo` (upstream → ours)
- Add `PathInfo::to_narinfo()` that delegates to the upstream conversion's `to_narinfo()` method
- Add `PathInfo::from_narinfo()` to parse upstream NarInfo responses into our type
- Use the narinfo conversion in `cache.rs` to replace hand-rolled narinfo field extraction

## Capabilities

### New Capabilities
- `pathinfo-compat`: Bidirectional conversion between local PathInfo and upstream snix PathInfo/NarInfo types

### Modified Capabilities

## Impact

- `snix-redox/src/pathinfo.rs` — new conversion impls and narinfo methods
- `snix-redox/src/cache.rs` — simplified narinfo handling using upstream types
- No changes to PathInfoDb storage format (still JSON files)
- No changes to existing field access patterns across the codebase
