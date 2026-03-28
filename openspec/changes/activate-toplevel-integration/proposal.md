## Why

The nix-darwin integration change added an `activate` script and `/etc/static` symlink pattern to the toplevel derivation, but the Rust `activate.rs` doesn't know about either. The Rust activation writes config files by hash comparison against the rootTree, manages GC roots through package store paths, and has no concept of `/run/current-system` or `/etc/static`. These two activation paths need to be unified so `snix system switch` actually uses the toplevel's activate script and symlink farm.

## What Changes

- Add `/etc/static` symlink management to Rust `activate.rs` — create the symlink pointing at the etc derivation, and create per-file `/etc/foo → /etc/static/foo` symlinks for managed files
- Add `/run/current-system` symlink management to Rust `activate.rs`
- Add toplevel store path tracking to the manifest so `snix system switch` can locate the toplevel and its etc derivation
- Create a VM integration test that validates the full activate → `/etc/static` → `/run/current-system` pipeline on a live Redox system

## Capabilities

### New Capabilities
- `etc-static-activation`: Rust activate manages `/etc/static` and per-file symlinks through the etc derivation
- `activate-vm-test`: VM integration test validating `/etc/static`, `/run/current-system`, and GC roots on a live system

### Modified Capabilities

## Impact

- `snix-redox/src/activate.rs` — Add etc/static management and /run/current-system link
- `snix-redox/src/system.rs` — Pass toplevel path through switch pipeline
- `nix/redox-system/modules/build/manifest.nix` — Add toplevel/etc store paths to manifest
- `nix/redox-system/profiles/` — New test profile for activation validation
- `nix/redox-system/test-scripts/` — New test script
- `nix/flake-modules/system.nix` — Wire new test into flake packages
