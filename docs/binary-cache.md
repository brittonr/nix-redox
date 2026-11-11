# Binary cache

A public binary cache is the difference between a multi-hour source build and a
few minutes of downloads. The repository includes a gated Cachix workflow; it
is inactive until the repository variable and secret below are configured.

## Enable the workflow

1. Create a Cachix cache for the project, for example `nix-redox`.
2. Add a repository variable:
   - **Settings → Secrets and variables → Actions → Variables**
   - `CACHIX_CACHE_NAME` = the cache name
3. Add a repository secret:
   - `CACHIX_AUTH_TOKEN` = a Cachix auth token with write access
4. Run the **Binary cache** workflow, or push to `main`.

The workflow builds `.#redox-minimal` and `.#redox-graphical` under
`cachix watch-exec`, which uploads their closures. It starts only when
`CACHIX_CACHE_NAME` is set; missing credentials fail the job rather than
silently skipping cache publication.

## Use the cache

With Cachix installed:

```bash
cachix use nix-redox
nix run github:brittonr/nix-redox
```

Or pass the substituter explicitly. The public key is shown by Cachix when the
cache is created:

```bash
nix build \
  --extra-substituters https://nix-redox.cachix.org \
  --extra-trusted-public-keys "<cache-public-key>" \
  github:brittonr/nix-redox
```

For the NixOS integration module, set the options rather than editing the
module:

```nix
programs.redox = {
  enable = true;
  binaryCacheUrl = "https://nix-redox.cachix.org";
  binaryCachePublicKey = "<cache-public-key>";
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
