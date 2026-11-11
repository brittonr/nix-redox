# Binary cache

A public binary cache is the difference between a multi-hour source build and a
few minutes of downloads.

The project cache is **`nix-redox`**:

- Substituter: `https://nix-redox.cachix.org`
- Public key: `nix-redox.cachix.org-1:d0dvP2sgt2k2M3MRT6lHm4S0AMAtOP6yiuvSDF8Khuc=`

The flake declares this cache in `nixConfig`; accept the flake configuration or
use `cachix use nix-redox`. The GitHub workflow pushes the minimal and graphical
images for Nix 2.24.9 and 2.35.1, the two versions used by CI.

**Nix store paths are version-dependent here.** A client whose Nix version
produces different derivation paths will miss the cache for those paths. Use a
matching Nix version for cache hits, or expect source builds on other versions.
Deliveries are still valid; they are simply not interchangeable across versions.

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
