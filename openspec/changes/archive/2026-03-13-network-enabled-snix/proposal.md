## Why

snix on Redox can already fetch from binary caches (`snix fetch --cache-url`) and install packages (`snix install`), but these only work with local filesystem caches (virtio-fs bridge at `/nix/cache/` or `/scheme/shared/cache`). The HTTP client (ureq) is compiled in and the `cache.rs` module has full remote fetch logic, but there's no end-to-end tested path for a Redox VM with real network connectivity to download packages from a remote server. With QEMU SLiRP networking already proven (e1000d → smolnetd → DHCP → DNS → TCP), and the self-hosting toolchain working, the next step is connecting these pieces: a Redox VM that boots with networking, discovers packages from a remote binary cache, and installs them over HTTP — no virtio-fs bridge required.

## What Changes

- **Remote binary cache as a first-class install source**: `snix install <name> --cache-url https://...` fetches packages.json from a remote HTTP binary cache, resolves the store path, downloads the NAR, and installs — same as local cache but over the network.
- **`snix search --cache-url`**: Search remote package indexes over HTTP (currently only searches local filesystem caches).
- **Unified cache abstraction**: Extract a `CacheSource` trait/enum that abstracts over local filesystem and remote HTTP caches, so `install`, `search`, and `show` work identically against both.
- **Network-enabled VM test infrastructure**: A new functional test profile that boots with QEMU SLiRP networking, serves a binary cache via Python's `http.server` on the host, and runs in-guest tests proving `snix install` works over the network.
- **TLS support (optional stretch)**: Enable ureq's `rustls` feature for HTTPS binary caches. Currently ureq is compiled with `default-features = false` (HTTP only) to avoid ring's C compilation. With the cross-compilation toolchain now working, rustls may be feasible.

## Capabilities

### New Capabilities
- `remote-binary-cache`: Fetching, searching, and installing packages from remote HTTP/HTTPS binary caches. Covers the unified cache abstraction, remote packages.json fetching, NAR download with hash verification, and recursive dependency resolution over the network.
- `network-install-testing`: VM-based integration tests for network package installation. Covers the host-side HTTP server setup, QEMU SLiRP networking configuration, and in-guest test scripts that verify end-to-end remote install.

### Modified Capabilities

## Impact

- **snix-redox/src/cache.rs**: Already has remote fetch logic; needs integration with install/search flows.
- **snix-redox/src/install.rs**: Currently hardcoded to local_cache; needs to accept remote URLs.
- **snix-redox/src/local_cache.rs**: Refactor search/index reading to work over HTTP too, or extract shared interface.
- **snix-redox/src/main.rs**: CLI changes — `--cache-url` on install/search/show commands.
- **snix-redox/Cargo.toml**: Possibly enable ureq rustls feature.
- **nix/pkgs/infrastructure/**: New test infrastructure (mkNetworkTest or extended mkFunctionalTest).
- **nix/redox-system/profiles/**: New network-test profile with QEMU SLiRP config.
- **No breaking changes**: Local cache paths continue to work as before; remote is additive.
