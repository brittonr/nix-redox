## Context

snix on Redox OS has two separate cache subsystems that don't interoperate:

1. **`cache.rs`** — Remote HTTP binary cache client. Fetches narinfo + NAR from URLs like `https://cache.nixos.org`. Used by `snix fetch` and `snix path-info`. Handles decompression (zstd, xz, bzip2), hash verification, and PathInfoDb registration. Uses ureq (sync HTTP, no TLS).

2. **`local_cache.rs`** — Local filesystem binary cache reader. Reads `packages.json` index and narinfo/NAR files from a local directory (e.g., `/nix/cache/` or `/scheme/shared/cache`). Used by `snix install`, `snix search`, and `snix show`.

The install/search/show commands only work with local caches. The fetch command only works with remote caches and requires the full store path (not a package name). There's no way to say `snix install ripgrep --cache-url https://my-cache.example.com/`.

Meanwhile, networking on Redox is proven end-to-end: QEMU SLiRP provides the guest 10.0.2.15/24 with DNS at 10.0.2.3. The full stack (e1000d → smolnetd → DHCP → DNS → TCP) was validated in the networking functional tests (9/9 pass). ureq HTTP GET calls should work if DNS and TCP work — but this hasn't been tested with real binary cache downloads.

## Goals / Non-Goals

**Goals:**
- `snix install <name> --cache-url <url>` downloads and installs a package over HTTP
- `snix search --cache-url <url>` lists available packages from a remote cache
- A unified cache abstraction so install/search/show don't need to know if the cache is local or remote
- VM integration tests proving network install works end-to-end (host HTTP server → guest install)
- Recursive dependency fetching over the network (`snix install --recursive`)

**Non-Goals:**
- HTTPS/TLS support (ureq is HTTP-only; rustls requires ring C compilation investigation — separate change)
- Running a cache.nixos.org-compatible server on the host (we use our own packages.json format)
- Nix binary cache signing/verification (signature fields are parsed but not verified)
- Multi-cache fallback chains (try cache A, fall back to cache B)
- Nix substituter protocol compatibility (we use our own simpler protocol)

## Decisions

### 1. Unified `CacheSource` enum instead of trait

**Decision**: Use an enum `CacheSource { Local(PathBuf), Remote(String) }` rather than a trait.

**Rationale**: There are only two variants (local filesystem, remote HTTP) and the operations are simple (read index, read narinfo, read NAR). An enum with match arms is simpler than trait objects, avoids lifetimes/allocation, and is easier to test. If a third source type is ever needed (e.g., S3), it's a straightforward enum variant addition.

**Alternative considered**: `trait CacheBackend` with `LocalCache` and `RemoteCache` impls. Rejected — too much indirection for two simple cases.

### 2. Remote packages.json as the package index

**Decision**: Remote caches serve `packages.json` at the cache root, same format as local caches. `snix install ripgrep` looks up the name in packages.json to get the store path, then fetches the narinfo + NAR.

**Rationale**: We already generate this file in `push-to-redox` / `build-binary-cache.py`. It's a simple JSON map from name → store path metadata. This is NOT the same as cache.nixos.org's format (which has no packages.json and requires knowing the store path hash in advance). Our format is purpose-built for name-based discovery.

**Alternative considered**: nix-channel-style listing. Rejected — our packages.json is already proven with the bridge workflow.

### 3. Host-side HTTP server for testing: Python http.server

**Decision**: Use `python3 -m http.server` on the host to serve the binary cache directory during VM tests.

**Rationale**: Zero dependencies (Python is in the Nix build sandbox), serves static files correctly, easy to start/stop. The cache directory is already built by `build-binary-cache.py`. QEMU SLiRP makes the host accessible at 10.0.2.2 from the guest.

**Alternative considered**: Nix's `serve-store` or a custom Rust server. Rejected — Python is simpler for testing and we only need static file serving.

### 4. QEMU SLiRP for test networking (no TAP/root)

**Decision**: Use QEMU user-mode networking (SLiRP) for the network install tests, with the host HTTP server bound to 0.0.0.0.

**Rationale**: QEMU SLiRP requires no root access, no TAP interface setup, and provides deterministic guest networking (10.0.2.15/24, gateway 10.0.2.2, DNS 10.0.2.3). The host-forwarding `-netdev user,id=net0,hostfwd=tcp::8080-:0` isn't needed — the guest reaches the host directly at 10.0.2.2. Already proven in the existing network functional tests.

### 5. Extend existing mkFunctionalTest rather than new mkNetworkTest

**Decision**: Add a `networking` option to `mkFunctionalTest` that adds QEMU SLiRP networking and the network-related profile.

**Rationale**: The test infrastructure (serial console polling, milestone checking, test result parsing) is the same. Only the QEMU flags and profile differ. A separate factory would duplicate 80% of the code.

## Risks / Trade-offs

- **[No TLS] → HTTP only**: Remote caches must be served over plain HTTP. Acceptable for LAN/localhost testing. TLS support is a separate change requiring rustls integration.
- **[ureq DNS on Redox untested]** → Mitigation: ureq uses `std::net::ToSocketAddrs` which calls `getaddrinfo()` in relibc. The networking tests proved DNS works (`nslookup` succeeds), but ureq's specific code path hasn't been exercised. VM tests will catch this.
- **[Large downloads may timeout]** → Mitigation: ureq defaults to no timeout. For large NARs (>100MB), the download could stall if the network stack has issues. Add configurable timeout via CLI flag.
- **[packages.json is our format, not standard Nix]** → Mitigation: Document clearly. This is intentional — standard Nix binary caches don't have name-based lookup. Our format serves the Redox use case better.
- **[Host port availability]** → Mitigation: Use a random high port for the test HTTP server and pass it to the guest via kernel cmdline or a file in the initfs. If port 8080 is busy, the test fails — use port 0 for auto-assignment.
