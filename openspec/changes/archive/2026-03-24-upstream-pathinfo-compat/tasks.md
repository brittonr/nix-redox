# Tasks

## Phase 1: Conversion impls in pathinfo.rs

- [x] 1.1 Add `to_upstream()` method on our PathInfo that returns `snix_store::path_info::PathInfo` — parse `nar_hash` from `"sha256:{hex}"` to `[u8; 32]`, convert `store_path`/`references`/`deriver` via `StorePath::from_absolute_path`, parse signatures via `Signature::parse`, use dummy `Node::File` for the node field
- [x] 1.2 Add `from_upstream()` constructor that takes `&snix_store::path_info::PathInfo` and returns `PathInfo` — encode `nar_sha256` back to `"sha256:{hex}"`, convert StorePaths to absolute path strings, stringify signatures, set `registration_time` to current, leave `files` empty
- [x] 1.3 Add `from_narinfo()` constructor that takes a `NarInfo` and store path string — extract `nar_hash`, `nar_size`, `references`, `signatures`, `deriver` from the narinfo
- [x] 1.4 Add `to_narinfo()` — deferred: requires to_upstream() to produce a valid NarInfo, but dummy node makes this unreliable. Will add when we have real castore Nodes.
- [x] 1.5 Add unit tests for round-trip conversion: our PathInfo → upstream → back, verify fields match; plus from_narinfo parsing test

## Phase 2: Use from_narinfo in cache.rs

- [x] 2.1 Replace the manual narinfo field extraction in `fetch_inner()` with `PathInfo::from_narinfo(&narinfo, &dest)` + `store::register_path_from_info()`
- [x] 2.2 Replace the manual field extraction in `fetch_recursive()` registration block with `PathInfo::from_narinfo()`
- [x] 2.3 Add `store::register_path_from_info()` that accepts `&PathInfo` directly

## Phase 3: Verify

- [x] 3.1 `nix build .#checks.x86_64-linux.snix-build` and `snix-clippy` — library compiles and clippy passes clean
- [x] 3.2 `nix build .#checks.x86_64-linux.functional-test` — VM test passes end-to-end
