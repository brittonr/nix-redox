## Context

The Rust `activate.rs` currently handles: atomic profile swap, config file diffing by BLAKE3 hash, manifest-derived file writes (hostname, timezone, dns), boot component updates, GC root management via store package roots, and activation script execution. It does NOT manage `/etc/static`, `/run/current-system`, or toplevel store paths.

The nix-darwin integration change added an Ion shell `activate` script in the toplevel, but the Rust code doesn't invoke it or replicate its behavior. The two activation paths must be unified.

## Goals / Non-Goals

**Goals:**
- Add `/etc/static` and `/run/current-system` management to the Rust activate, converging with the Ion script's behavior
- Track toplevel and etc derivation paths in the manifest so activate can locate them
- Validate the full pipeline in a VM integration test

**Non-Goals:**
- Replace Rust activate with the Ion script (Rust handles profile swap and config diffing which the Ion script doesn't)
- Change how `snix system rebuild` evaluates configuration.nix
- Add service restart detection (future work)

## Decisions

### 1. Manifest extensions

Add two fields to the manifest JSON:

```json
{
  "toplevel": "/nix/store/...-redox-toplevel-redox",
  "etcSource": "/nix/store/...-redox-etc"
}
```

These are set at build time in `manifest.nix`. The Rust `Manifest` struct gains `toplevel: Option<String>` and `etc_source: Option<String>` (Option for backward compat with v1/v2 manifests).

### 2. /etc/static in Rust activate

After step 3 (config file updates), add a new step:

```
Step 3c: Update /etc/static
  if manifest.etc_source is Some(path):
    1. ln -sfn $path /etc/static
    2. Walk $path recursively, for each file at relative path P:
       - If /etc/$P is NOT a symlink through /etc/static, create it
    3. Walk /etc/ for symlinks targeting old /etc/static — remove stale ones
```

This runs alongside (not replacing) the existing config file hash diffing. The hash diffing handles content verification; /etc/static handles the symlink farm.

On first activation (fresh system, no /etc/static), the symlinks are created from scratch. Existing baked-in files at /etc/ are replaced with symlinks.

### 3. /run/current-system in Rust activate

After step 4 (GC roots), add:

```
Step 4b: Update /run/current-system
  if manifest.toplevel is Some(path):
    mkdir -p /run
    ln -sfn $path /run/current-system
    mkdir -p /nix/var/nix/gcroots
    ln -sfn /run/current-system /nix/var/nix/gcroots/current-system
```

### 4. VM test

New profile `activate-toplevel-test.nix` based on the functional-test pattern. Test script:
1. Verify initial state (manifest exists, snix exists)
2. Run `snix system switch /etc/redox-system/manifest.json` (switch to self — triggers full activate)
3. Verify `/etc/static` is a symlink to a store path
4. Verify `/run/current-system` is a symlink
5. Verify `/nix/var/nix/gcroots/current-system` exists
6. Verify a managed file like `/etc/hostname` is symlinked through `/etc/static`

## Risks / Trade-offs

- **[Backward compat]** Old manifests without `toplevel`/`etcSource` skip the new steps. The `Option<String>` fields handle this gracefully.
- **[First boot transition]** Replacing baked-in files with symlinks on first activation: the file content is identical (etc derivation matches rootTree etc), so the switch is safe. The baked-in file is removed and replaced with a symlink.
- **[Redox symlink semantics]** `ln -sf` on Redox requires the target to exist if the parent directory is in redoxfs. The etc derivation store path exists in `/nix/store/` on the rootfs, so this works.
