## Why

Redox still carries several vendored crates, forked crate sources, and one-off vendor patches long after upstream has moved on. That drift raises upgrade cost, hides which local deltas are still necessary, and keeps us exposed to stale dependency trees when an upstream crate or release would already work.

## What Changes

- Audit the current vendored-crate and forked-source surface across `nix/pkgs/`, `snix-redox/`, and source-bundle derivations.
- Keep the live inventory in [`evidence/crate-inventory.md`](./evidence/crate-inventory.md).
- Classify each case as one of: update directly to upstream, keep a local carry with documented blocker, or defer because Redox-specific behavior still needs a patch.
- Replace vendored or forked crate sources with upstream releases/commits where validation shows Redox behavior stays correct.
- Tighten the maintenance path for the crates we still vendor locally: record why they remain local, what test protects them, and what would let us upstream or drop the delta later.

## Capabilities

### New Capabilities
- `vendored-crate-upstream-sync`: Selectively converge vendored crates and forked crate sources back to upstream while documenting the exceptions that still need Redox-local carry.

### Modified Capabilities

None.

## Impact

- **Build packaging**: `nix/pkgs/userspace/`, `nix/pkgs/system/`, `nix/pkgs/infrastructure/`, and shared vendor helpers in `nix/lib/vendor.nix`.
- **Upstream-sourced workspaces**: `snix-redox/` and `nix/pkgs/infrastructure/snix-upstream-source.nix`.
- **Dependency state**: Cargo.lock files, vendor hashes, patched vendored crates, and source-bundle contents.
- **Validation**: host builds/checks plus focused VM or self-hosting coverage for crates that affect guest-native behavior.
