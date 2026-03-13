## Why

The HTTP binary cache pipeline works end-to-end (8/8 tests pass with mock-hello), and TLS landed with rustls+ring. Three gaps remain: (1) no standalone `serve-cache` command for interactive use — the HTTP server is embedded in the test script, (2) the network install test only exercises a trivial mock package, not a real cross-compiled binary like ripgrep, and (3) there's no VM test proving that `snix fetch` works against `https://cache.nixos.org` despite TLS support being in place.

## What Changes

- Add a `serve-cache` Nix package: a standalone command that serves any binary cache directory over HTTP. Usable interactively (`nix run .#serve-cache`) and composable into test scripts.
- Extend the network install test to include a real cross-compiled package (ripgrep) alongside mock-hello, verifying that a multi-megabyte binary downloads, extracts, and executes correctly over HTTP.
- Add a new VM test (`https-cache-test`) that boots with networking and fetches a known store path from `https://cache.nixos.org`, proving the full TLS stack works in-guest against a real HTTPS endpoint.

## Capabilities

### New Capabilities
- `serve-cache`: Standalone HTTP file server command for binary cache directories.
- `real-package-http-test`: Network install test with real cross-compiled packages (ripgrep).
- `https-upstream-cache-test`: VM test fetching from cache.nixos.org over HTTPS.

### Modified Capabilities

(none)

## Impact

- New Nix packages: `serve-cache`, updated `network-install-test`, new `https-cache-test`.
- New test profile for HTTPS cache testing.
- The ripgrep test cache adds ~3MB to the test binary cache build (zstd-compressed NAR).
- The HTTPS test requires outbound internet access from the VM (QEMU SLiRP provides this by default).
