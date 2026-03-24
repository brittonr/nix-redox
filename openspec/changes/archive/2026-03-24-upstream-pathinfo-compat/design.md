## Context

Our `pathinfo::PathInfo` uses raw strings for store paths, hashes, references, and signatures. Upstream `snix_store::path_info::PathInfo` uses typed wrappers: `StorePath<String>`, `[u8; 32]` for nar_sha256, `Vec<Signature<String>>`, plus a mandatory `node: Node` and optional `ca: Option<CAHash>`. When we fetch from binary caches, `cache.rs` manually extracts narinfo fields into strings. When we build, `local_build.rs` constructs our PathInfo from strings. Neither path can interop with upstream's PathInfoService or signature verification.

## Goals / Non-Goals

**Goals:**
- Bidirectional conversion: our PathInfo ↔ upstream PathInfo
- NarInfo conversion: our PathInfo → upstream NarInfo (for serving) and upstream NarInfo → our PathInfo (for cache fetching)
- Simplify `cache.rs` narinfo→PathInfo conversion using the new methods
- Keep our PathInfo type and JSON storage unchanged

**Non-Goals:**
- Replacing our PathInfo type with upstream's
- Changing the PathInfoDb storage backend
- Producing real castore Nodes (use a dummy placeholder)
- Changing any of the 126 field access sites

## Decisions

### Dummy Node for our→upstream conversion

Upstream's PathInfo requires `node: Node`. We don't have castore content addressing yet. Use `Node::File { digest: B3Digest::default(), size: 0, executable: false }` as a placeholder. Code that receives the converted PathInfo and needs the real node must handle this — we document the limitation.

### Parse nar_hash string into [u8; 32]

Our `nar_hash` field is `"sha256:{hex}"`. The conversion strips the `sha256:` prefix and decodes the hex into `[u8; 32]`. The reverse adds the prefix back.

### StorePath parsing for store_path, references, deriver

Our fields are absolute path strings. Conversion uses `StorePath::from_absolute_path()`. Failure in `TryFrom` returns an error — callers handle it.

### Signature parsing

Our `signatures: Vec<String>` stores `"keyname:base64sig"` strings. Upstream's `Signature<String>` parses the same format via `Signature::parse()`.

### from_narinfo constructor

A `PathInfo::from_narinfo(narinfo, store_path_str)` constructor takes an upstream `NarInfo` and the full store path string, producing our PathInfo. This replaces the scattered field extraction in `cache.rs`.

## Risks / Trade-offs

**[Dummy Node]** Any code that receives an upstream PathInfo from our conversion and inspects the node will get garbage. → Documented. Only matters when we start using PathInfoService::put(), which is a future change.

**[String parsing round-trips]** Converting our string-based fields to typed wrappers and back is slightly lossy (e.g., trailing slashes, case). → All our store paths are produced by nix-compat which guarantees canonical format.
