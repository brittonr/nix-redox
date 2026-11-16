# Binary cache

A public binary cache is the difference between a multi-hour source build and a
few minutes of downloads.

The project cache is **`nix-redox`**:

- Substituter: `https://nix-redox.cachix.org`
- Public key: `nix-redox.cachix.org-1:d0dvP2sgt2k2M3MRT6lHm4S0AMAtOP6yiuvSDF8Khuc=`

The flake declares this cache in `nixConfig`; accept the flake configuration or
use `cachix use nix-redox`. The GitHub workflow pushes the minimal and graphical
images for Nix 2.24.9 and 2.35.1, the two versions used by CI. Flake-free builds
([`nixtamal.md`](nixtamal.md)) produce the same store paths but ignore
`nixConfig`, so they need the substituter configured in `nix.conf` or by Cachix.

**Nix store paths are version-dependent here.** A client whose Nix version
produces different derivation paths will miss the cache for those paths. Use a
matching Nix version for cache hits, or expect source builds on other versions.
Deliveries are still valid; they are simply not interchangeable across versions.

A cold-store verification was run with Nix 2.36 and a matching 2.35.1 cache
entry: the minimal image fetched its heavy components from `nix-redox` and only
assembled the final disk-image derivation locally (~89 seconds). The final
image assembly may still run on the client even when its outputs are cached.

## Publishing

The cache name and auth token are configured as the repository variable
`CACHIX_CACHE_NAME` and secret `CACHIX_AUTH_TOKEN`. The **Binary cache**
workflow runs on every push to `main` and builds `.#redox-minimal` and
`.#redox-graphical` for each supported Nix version under `cachix watch-exec`.

To publish from a fork, create a token with write access and set the same
variable and secret. If a token is missing, the workflow logs a warning and
skips cleanly.

## Use the cache

With Cachix installed:

```bash
cachix use nix-redox
nix run github:brittonr/nix-redox
```

Or accept the flake's cache configuration and pass the substituter explicitly:

```bash
nix build \
  --accept-flake-config \
  --extra-substituters https://nix-redox.cachix.org \
  --extra-trusted-public-keys "nix-redox.cachix.org-1:d0dvP2sgt2k2M3MRT6lHm4S0AMAtOP6yiuvSDF8Khuc=" \
  github:brittonr/nix-redox
```

For the NixOS integration module, set the options rather than editing the
module:

```nix
programs.redox = {
  enable = true;
  binaryCacheUrl = "https://nix-redox.cachix.org";
  binaryCachePublicKey = "nix-redox.cachix.org-1:d0dvP2sgt2k2M3MRT6lHm4S0AMAtOP6yiuvSDF8Khuc=";
};
```

The module no longer injects a private cache or key by default.

## Trust policy

A binary cache is an optimization, not a trust anchor. Only add caches and keys
you trust; a compromised cache can serve modified store paths. Cachix signs
narinfos, and Nix verifies the configured public key. The cache contains build
outputs from this repository's CI workflow, not arbitrary user uploads.

## Maintainer tools

The generic `push-cache` and `cache-status` apps require an explicit cache URL:

```bash
nix run .#push-cache -- ssh-ng://cache.example
nix run .#cache-status -- https://cache.example
nix run .#serve-cache -- ./cache-dir
```

No host, key, or cache URL is hardcoded in the public tree.

## Guest/offline cache closures

The host Cachix substituter above is separate from the cache consumed by the
Redox Snix CLI. `nix/lib/mk-binary-cache.nix` accepts named installable roots and
uses Nix's complete runtime reference graph; it does not treat the supplied
roots as standalone payloads or erase inconvenient references.

The export contains:

| File | Version | Contract |
|---|---|---|
| `packages.json` | 2 | Named installable roots, compatibility evidence, `closureManifestVersion = 1`, `installationMode = "recursive"` |
| `closure.json` | 1 | Every closure path, truthful sorted direct references, payload identity and per-path compatibility |
| `*.narinfo` | Nix narinfo | Actual store identity, NAR hash/size, compression/file hash/size, and direct `References` |
| `transport.json` | 1 | Per-selected-root inventory of required cache files with transfer sizes and SHA-256 hashes |

Only intended products appear in the package index. Internal dependencies are
still exported and traversed. Chains, diamonds and self-references terminate;
missing paths, unresolved references or missing payloads fail instead of
producing a root-only approximation.

Native compatibility is declared build evidence, not a package-name heuristic:
root `TARGET`, `CARGO_BUILD_TARGET`, or the derivation's host-platform coordinate.
Use `pathMetadata = [ { path = "${dependency}"; target = "x86_64-unknown-redox";
evidence = "description of target build evidence"; } ];` for a native dependency
whose target is otherwise unavailable. Keep the Nix string context in `path`.
Content-classified scripts/data use `target = "any"`; a host-created data file is
not automatically a host executable. A wrong-target native dependency is an
export failure, never filtered from the graph.

Every installation now follows narinfo references, including ordinary local
and lazy installation. `snix install NAME --recursive --cache-path /nix/cache`
remains an explicit spelling of the same complete-closure behavior. The guest
checks v2 root compatibility before installing. Legacy v1 standalone indexes
remain readable for curated workflows; they do not supply v2's target-evidence
contract. Unknown schema versions fail explicitly.

The fixture root `cache-closure-fixture` is a real Redox executable A that reads
data from B, whose contents reference C. Its catalog exposes A only. Host export
checks prove the graph, but successful execution after recursive guest install
is the separate runtime gate. Compiler source filenames must be remapped at
their actual producers, including relibc, so diagnostics do not accidentally
turn a guest executable into a reference to the host toolchain. Genuine runtime
references remain untouched.

The [browser transport](browser-demo.md#downloaded-guest-packages) downloads only
a selected root's inventory. Hash pinning detects changed bytes; it does not
make an untrusted publisher trustworthy or replace the host cache's signature
policy.

The browser transport trusts the operator of the loaded site and release
manifest. That manifest pins the transport inventory, which binds the selected
objects and target metadata. It does not verify Cachix signatures or
independently authenticate the publisher. Serve the site over trusted HTTPS
(plain HTTP is for loopback development): hashes cannot detect an attacker who
can replace both the release manifest and its payloads.
