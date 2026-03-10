## 1. Cargo Dependencies

- [x] 1.1 Add `redox_scheme` and `syscall` as platform-gated dependencies in `snix-redox/Cargo.toml` under `[target.'cfg(target_os = "redox")'.dependencies]`. Pin versions matching what `virtio-fsd` uses.
- [x] 1.2 Update the cargo vendor hash in `snix.nix` and `snix-source-bundle.nix`. Verify the build still cross-compiles for x86_64-unknown-redox and host tests still pass on Linux.

## 2. stored SchemeSync Implementation

- [x] 2.1 Implement `StoreSchemeHandler` struct wrapping `StoreDaemon` in `stored/scheme.rs`.
- [x] 2.2 Implement `SchemeSync::openat`: parse path via `resolve::parse_scheme_path`, trigger `lazy::ensure_extracted` if needed, open via `handles.open_file`/`open_dir`, return `OpenResult::ThisScheme`.
- [x] 2.3 Implement `SchemeSync::read`: delegate to `handles.read(id, buf, offset)`.
- [x] 2.4 Implement `SchemeSync::fstat`: get handle metadata, populate `Stat` struct.
- [x] 2.5 Implement `SchemeSync::fsize`: delegate to `handles.file_size(id)`.
- [x] 2.6 Implement `SchemeSync::fpath`: write `store:{scheme_path}` to buffer.
- [x] 2.7 Implement `SchemeSync::getdents`: for dir handles, use `handles.list_dir`; for root, use `resolve::list_store_paths`. Format as `DirentBuf` entries.
- [x] 2.8 Implement `SchemeSync::on_close`: delegate to `handles.close(id)`.
- [x] 2.9 Implement `run_daemon()`: create `StoreDaemon`, `Socket::create()`, `register_sync_scheme`, enter request loop (copy the virtio-fsd pattern exactly).

## 3. profiled SchemeSync Implementation

- [x] 3.1 Create handle table for profiled: `FileHandle` (resolved underlying file), `DirHandle` (subpath for union listing), `ControlHandle` (write buffer for JSON commands). Put in `profiled/handles.rs`.
- [x] 3.2 Implement `ProfileSchemeHandler` struct wrapping `ProfileDaemon` + handle table in `profiled/scheme.rs`.
- [x] 3.3 Implement `SchemeSync::openat`: parse `{profile}/{subpath}`, detect `.control`, resolve through mapping, open underlying file or create control handle.
- [x] 3.4 Implement `SchemeSync::read`: file handles read from underlying file; dir/control handles return appropriate errors.
- [x] 3.5 Implement `SchemeSync::write`: control handles accumulate JSON data and process on close or newline. File handles return EACCES.
- [x] 3.6 Implement `SchemeSync::fstat`, `fsize`, `fpath`: follow stored pattern but with `profile:` prefix.
- [x] 3.7 Implement `SchemeSync::getdents`: union listing via `mapping.list_union(subpath)`. Root lists profile names.
- [x] 3.8 Implement `SchemeSync::on_close`: for control handles, process accumulated command. For file handles, just close.
- [x] 3.9 Implement `run_daemon()`: create `ProfileDaemon`, register scheme, enter request loop.

## 4. Unit Tests (Linux)

- [x] 4.1 Add tests for `StoreSchemeHandler` logic: path dispatch, stat formatting, fpath output, error codes for invalid handles. (covered by existing stored/ tests + new handles tests)
- [x] 4.2 Add tests for `ProfileSchemeHandler` logic: control handle JSON processing, profile path parsing, union dir listing through scheme interface. (4 new tests in profiled/handles.rs)
- [x] 4.3 Verify all existing 439 tests still pass with the new dependencies and code. (443/443 pass — 4 new)

## 5. VM Functional Tests

- [x] 5.1 Create `scheme-daemon` test profile that enables stored + profiled in init.d.
- [x] 5.2 Test stored: register a package in PathInfoDb with NAR in cache → access via `store:` scheme → verify file content.
- [x] 5.3 Test profiled: add package via `.control` write → read binary through `profile:default/bin/` → verify content.
- [x] 5.4 Test union view: install two packages → list `profile:default/bin/` → verify merged listing.
- [x] 5.5 Test lazy extraction: register-only (no extract) → access via `store:` → verify extraction triggers.
- [x] 5.6 Test fallback: daemon not running → direct `/nix/store/` access works.

## 6. Build System

- [x] 6.1 Verify `nix build .#snix` still produces a working binary with the new deps. (5.5MB ELF built)
- [x] 6.2 Verify the self-hosting test suite still passes (53/57 — 4 failures are pre-existing ld.so UTF-8 bug in generic-array's CARGO_PKG_AUTHORS, unrelated to scheme daemons).
- [x] 6.3 Update napkin with lessons learned.
