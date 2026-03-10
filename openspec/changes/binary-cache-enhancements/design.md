## Context

The network install pipeline already works: `test-binary-cache.nix` builds a cache with mock-hello, `network-install-test.nix` boots QEMU with SLiRP and serves the cache via `python3 -m http.server`, and the guest installs via `snix install --cache-url http://10.0.2.2:18080`. TLS support (rustls+ring) landed, so `snix fetch --cache-url https://cache.nixos.org` compiles but has no VM test coverage.

Key constraints:
- QEMU SLiRP gives the guest access to the host at `10.0.2.2` and the internet via NAT.
- The test binary cache uses flat layout (NARs in root, not `nar/` subdirectory) per AGENTS.md.
- Ion shell test scripts use `$()` for command substitution which crashes on empty output.
- `sleep` doesn't work on Redox — DHCP polling uses `cat /scheme/sys/uname` as a delay source.
- The HTTPS test needs outbound internet — QEMU SLiRP provides this without any special setup.

## Goals / Non-Goals

**Goals:**
- A reusable `serve-cache` command that can serve any cache directory.
- Prove that real cross-compiled packages (ripgrep, ~6MB binary) install correctly over HTTP.
- Prove that `snix fetch` works against `https://cache.nixos.org` from inside a Redox VM.

**Non-Goals:**
- Replacing virtio-fs bridge with HTTP (bridge handles bidirectional build requests, not just fetching).
- Cache signing or trust verification (future work).
- Running a persistent cache server daemon in production (this is for dev/test use).

## Decisions

### 1. serve-cache: Python http.server wrapped in a Nix script

**Rationale:** Already proven in network-install-test. Zero additional dependencies. Serves static files which is all a Nix binary cache needs. The existing `python3 -m http.server` call is extracted into a standalone `writeShellScriptBin`.

**Alternatives considered:**
- `darkhttpd` / `miniserve` — extra dependency for no gain; Python is already in the build closure.
- `nix serve` — only speaks the Nix binary cache protocol, not plain HTTP file serving, and requires a running Nix daemon.

### 2. Test cache includes ripgrep via the existing cross-compilation pipeline

**Rationale:** ripgrep is already a known package in `push-to-redox.nix` and builds reliably. Including it in `test-binary-cache.nix` alongside mock-hello exercises a real multi-crate Rust binary.

**Implementation:** Add ripgrep's store path to the `packageInfo` list in `test-binary-cache.nix`. The cache builder serializes it to NAR+zstd just like mock-hello.

### 3. HTTPS test fetches a specific store path from cache.nixos.org

**Rationale:** We need a stable store path that won't be garbage-collected from cache.nixos.org. The `hello` package on nixpkgs master is effectively permanent. We hardcode its store path and narinfo hash for the test.

**Implementation:** New profile `https-cache-test.nix` with an Ion test script. The script waits for DHCP, then runs `snix path-info <store-path> --cache-url https://cache.nixos.org` to verify narinfo fetch over HTTPS. We do NOT install the package (it's x86_64-linux, not x86_64-unknown-redox) — we just verify the HTTPS GET + narinfo parse succeeds.

### 4. QEMU SLiRP networking for all tests (no TAP/KVM required)

**Rationale:** Consistency with the existing network test. SLiRP works in CI without root. The HTTPS test needs outbound internet which SLiRP provides via NAT.

## Risks / Trade-offs

- [HTTPS test requires internet] → Test is skipped or marked SKIP if `cache.nixos.org` is unreachable. The test emits `FUNC_TEST:https-narinfo:SKIP:no-internet` instead of FAIL.
- [cache.nixos.org could GC the test store path] → Use `hello` from a recent stable nixpkgs; if it breaks, update the hash. The test script includes the expected hash for quick diagnosis.
- [ripgrep adds ~3MB to test cache build time] → Acceptable; ripgrep is already built as part of the normal development flow and is cached by Nix.
- [SLiRP DNS may not resolve cache.nixos.org] → QEMU SLiRP forwards DNS to the host's resolver. If host can resolve it, guest can too.
