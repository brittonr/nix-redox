## 1. Prototype: Validate Kernel Mechanism

- [x] 1.1 Write a minimal test program (Rust, cross-compiled for Redox) that calls `mkns` without `file`, then `register_scheme_to_ns(child_ns_fd, "file", cap_fd)` — confirm the kernel accepts registering a userspace scheme named `file` in a child namespace
- [x] 1.2 Extend the test to fork a child, `setns` to the child namespace, and verify the child's `open("file:/tmp/test")` arrives at the proxy (not redoxfs)
- [x] 1.3 Verify that `exec()` in the child resolves the builder binary path through the proxy's `file:` scheme — confirm the proxy must handle the exec-time open
- [x] 1.4 Measure round-trip latency: time a single `open` + `read` + `close` through the proxy vs direct `file:` access — establish baseline overhead

## 2. Allow-List and Path Matching

- [x] 2.1 Create `snix-redox/src/build_proxy/allow_list.rs` with `AllowList` struct containing `read_only: HashSet<PathBuf>` and `read_write: HashSet<PathBuf>`, and a `check(path) -> Permission` method using prefix matching
- [x] 2.2 Add `build_allow_list(drv, known_paths, output_dir, tmp_dir) -> AllowList` function that resolves input derivation outputs and input sources to store paths, adds `$out` and `$TMPDIR` as read-write
- [x] 2.3 Add prefix-matching edge case handling: ensure `/nix/store/abc-dep-1.0-other` does NOT match `/nix/store/abc-dep-1.0` (require path separator or exact match after the prefix)
- [x] 2.4 Write unit tests: allowed reads, blocked reads, allowed writes, blocked writes, prefix boundary cases, empty allow-list

## 3. Proxy Scheme Handler

- [x] 3.1 Create `snix-redox/src/build_proxy/mod.rs` module structure with `#[cfg(target_os = "redox")]` gating
- [x] 3.2 Implement `ProxyHandle` enum (`File { real_fd, path, writable }`, `Dir { real_path, scheme_path }`) and handle table with ID generation
- [x] 3.3 Implement `SchemeSync::openat` — parse path, check allow-list, open real file via `std::fs`, return handle ID. Return `EACCES` for disallowed paths
- [x] 3.4 Implement `SchemeSync::read` — look up handle, `seek` + `read` on real fd, return bytes
- [x] 3.5 Implement `SchemeSync::write` — check handle is writable, forward write to real fd
- [x] 3.6 Implement `SchemeSync::fstat` — stat the real fd, return `Stat` struct
- [x] 3.7 Implement `SchemeSync::fsize` — return file size from real fd metadata
- [x] 3.8 Implement `SchemeSync::getdents` — list real directory, filter entries against allow-list, return filtered listing
- [x] 3.9 Implement `SchemeSync::fpath` — return scheme-relative path for the handle
- [x] 3.10 Implement `SchemeSync::on_close` — close real fd, remove from handle table
- [x] 3.11 Implement `scheme_root` — return handle for the root directory

## 4. Proxy Lifecycle Management

- [x] 4.1 Create `BuildFsProxy` struct with `start(child_ns_fd, allow_list) -> Result<Self>` that creates a `Socket`, calls `register_scheme_to_ns`, and spawns the event loop thread
- [x] 4.2 Implement `BuildFsProxy::shutdown(self)` — close the socket fd to terminate the event loop, join the thread
- [x] 4.3 Handle proxy thread panics — wrap event loop in `catch_unwind`, log errors, ensure the builder still gets killed if the proxy dies
- [x] 4.4 Add non-Redox stub for `BuildFsProxy` that does nothing (for cross-compilation and host tests)

## 5. Integration with local_build.rs

- [x] 5.1 Modify `build_derivation_inner` to build `AllowList` from derivation inputs before fork
- [x] 5.2 Replace the current `mkns([file, memory, pipe, ...])` call with `mkns([memory, pipe, rand, null, zero])` (no `file`)
- [x] 5.3 Start `BuildFsProxy` with the child namespace fd and allow-list before forking
- [x] 5.4 Update `pre_exec` closure to `setns(child_ns_fd)` (same as before, but now the namespace has proxy-file instead of real-file)
- [x] 5.5 After builder exits, call `proxy.shutdown()` and join the thread
- [x] 5.6 Preserve fallback: if proxy start fails, fall back to current behavior (include real `file` in namespace, log warning)

## 6. Symlink Handling

- [x] 6.1 In `openat`, after resolving the requested path, check if it's a symlink — if so, resolve the target and re-check against the allow-list
- [x] 6.2 Handle chains of symlinks (resolve until non-symlink, check final target)
- [x] 6.3 Add tests: symlink within allowed prefix (pass), symlink crossing to disallowed prefix (block), symlink chain

## 7. Unit Tests (Host)

- [x] 7.1 AllowList: prefix matching, boundary cases, read-only vs read-write permission checks
- [x] 7.2 Path resolution: absolute paths, relative components, `..` traversal attempts
- [x] 7.3 Directory filtering: `getdents` returns only allowed entries from a larger real listing
- [x] 7.4 Handle table: open/read/write/close lifecycle, handle reuse after close

## 8. Update Existing Sandbox Module

- [x] 8.1 Update `sandbox.rs` documentation to reference the proxy (no longer the only sandboxing layer)
- [x] 8.2 Remove `file` from `REQUIRED_SCHEMES` constant (proxy replaces it)
- [x] 8.3 Update `setup_build_namespace` to not include `file` — the caller handles proxy registration separately
- [x] 8.4 Update sandbox unit tests to reflect new scheme list

## 9. VM Integration Tests

- [x] 9.1 Add a functional test: build a derivation that tries to read `/etc/passwd` — verify it fails with the proxy active
- [x] 9.2 Add a functional test: build a derivation that reads a declared input store path — verify it succeeds
- [x] 9.3 Add a functional test: build a derivation that tries to read an undeclared store path — verify it fails
- [x] 9.4 Add a functional test: build a derivation that writes to `$out` and reads it back — verify success
- [x] 9.5 Verify existing self-hosting tests still pass (cargo builds, proc-macros, snix self-compile) with the proxy active
- [x] 9.6 Add a fallback test: build with `--no-sandbox` and verify it still works
