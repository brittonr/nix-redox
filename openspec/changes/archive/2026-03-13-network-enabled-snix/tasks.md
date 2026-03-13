## 1. Unified Cache Abstraction

- [x] 1.1 Create `CacheSource` enum in `snix-redox/src/cache_source.rs` with `Local(PathBuf)` and `Remote(String)` variants. Implement `from_args()` that parses `--cache-url` (HTTP URL) vs `--cache-path` (filesystem path) vs default `/nix/cache`.
- [x] 1.2 Add `read_index()` method on `CacheSource` — for Local, delegates to `local_cache::read_index()`; for Remote, HTTP GETs `{url}/packages.json` via ureq and parses in memory.
- [x] 1.3 Add `fetch_narinfo()` method on `CacheSource` — for Local, reads `{path}/{hash}.narinfo` from filesystem; for Remote, HTTP GETs from URL. Both parse via `nix_compat::narinfo::NarInfo::parse()`.
- [x] 1.4 Add `fetch_nar()` method on `CacheSource` — for Local, opens NAR file from filesystem; for Remote, HTTP GETs the NAR URL. Returns a `Box<dyn Read>` for the (possibly compressed) stream.
- [x] 1.5 Write unit tests for `CacheSource`: URL detection, local path detection, default cache path, `SNIX_CACHE_PATH` env var handling.

## 2. Remote Install / Search / Show

- [x] 2.1 Refactor `install::install()` to accept `CacheSource` instead of `cache_path: &str`. The install flow (lookup → fetch narinfo → download NAR → decompress → verify hash → extract → register → symlink) stays the same but reads through `CacheSource`.
- [x] 2.2 Refactor `local_cache::search()` to work with `CacheSource` — extract the common search/display logic, use `CacheSource::read_index()` for the package listing.
- [x] 2.3 Refactor `install::show()` to accept `CacheSource` for remote package info display.
- [x] 2.4 Add `--cache-url` argument to `Install`, `Search`, and `Show` CLI commands in `main.rs`. When present, construct `CacheSource::Remote`. Keep `--cache-path` as before for backward compatibility.
- [x] 2.5 Implement recursive remote dependency fetching in `install::install()` — when `--recursive` flag is set with a remote cache, BFS-traverse narinfo references and fetch each missing dependency.
- [x] 2.6 Write unit tests for remote install flow: mock HTTP responses, verify hash checking, error handling for unreachable servers, malformed JSON, and package-not-found.

## 3. Network Test Infrastructure

- [x] 3.1 Create `network-test` profile in `nix/redox-system/profiles/` that extends the functional-test profile with networking (e1000d driver, smolnetd, dhcpd, dnsd) and a test startup script.
- [x] 3.2 Build a test binary cache at Nix build time using `build-binary-cache.py` with 3 test packages (ripgrep, fd, and a small mock package). The cache must NOT be included in the disk image.
- [x] 3.3 Create `mkNetworkInstallTest` factory in `nix/pkgs/infrastructure/` (or extend `mkFunctionalTest` with a `networking` option) that: starts Python HTTP server on port 8080 serving the test cache, boots QEMU with SLiRP networking (`-netdev user,id=net0 -device e1000,netdev=net0`), polls serial log for test results.
- [x] 3.4 Wire the network install test into `flake.nix` as `nix run .#network-install-test`.

## 4. In-Guest Test Script

- [x] 4.1 Write the network-test startup script (Ion shell) that waits for DHCP, verifies HTTP connectivity to `http://10.0.2.2:8080/packages.json`, and emits `FUNC_TEST:net-connectivity:PASS/FAIL`.
- [x] 4.2 Add `snix search --cache-url http://10.0.2.2:8080` test — verify packages are listed, emit `FUNC_TEST:net-search:PASS/FAIL`.
- [x] 4.3 Add `snix install <pkg> --cache-url http://10.0.2.2:8080` test — verify the binary is installed and executable, emit `FUNC_TEST:net-install:PASS/FAIL`.
- [x] 4.4 Add store path verification test — check `/nix/store/` for the installed path, emit `FUNC_TEST:net-store-path:PASS/FAIL`.
- [x] 4.5 Add idempotency test — run `snix install` again, verify "already installed" output, emit `FUNC_TEST:net-install-idempotent:PASS/FAIL`.
- [x] 4.6 Add `snix show <pkg> --cache-url` test — verify package info display, emit `FUNC_TEST:net-show:PASS/FAIL`.

## 5. Integration and Verification

- [x] 5.1 Run full network install test end-to-end (`nix run .#network-install-test`) and verify all `FUNC_TEST:` markers pass.
- [x] 5.2 Run existing functional tests (`nix run .#functional-test`) to verify no regressions.
- [x] 5.3 Run existing self-hosting tests (`nix run .#self-hosting-test` or the relevant test runner) to verify snix cross-compilation still works with the new code.
- [x] 5.4 Update `snix-redox/Cargo.toml` vendor hash if dependencies changed, verify `nix build .#snix-redox` succeeds.
- [x] 5.5 Update napkin with lessons learned.
