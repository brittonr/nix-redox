## Why

Profiles and user configurations can't inject arbitrary files into `/etc/` or run custom commands during system activation. Every new config file requires editing the hardcoded `generated-files.nix` in the build module. NixOS solves this with `environment.etc` and `system.activationScripts` — two primitives that make the module system extensible without touching internal build code.

## What Changes

- Add `environment.etc` option to the `/environment` module — an attrset of `{ text, source, mode }` entries that get merged into the root tree at build time alongside the existing generated files
- Add `system.activationScripts` option to a new `/activation` module — named script entries with optional `deps` ordering that `activate.rs` executes during `snix system switch`/`activate-boot`
- Existing hardcoded generated files (`/etc/profile`, `/etc/passwd`, etc.) continue to work unchanged — `environment.etc` entries merge alongside them
- Profiles can now declare files and activation hooks without build module changes

## Capabilities

### New Capabilities
- `environment-etc`: Declarative arbitrary file injection into `/etc/` via `environment.etc` option
- `activation-scripts`: User-extensible activation hooks run during `snix system switch` via `system.activationScripts`

### Modified Capabilities

## Impact

- `nix/redox-system/modules/environment.nix` — new `etc` option
- New `nix/redox-system/modules/activation.nix` module
- `nix/redox-system/modules/build/generated-files.nix` — merge `environment.etc` entries into `allGeneratedFiles`
- `nix/redox-system/modules/build/config.nix` — wire new `/activation` inputs
- `nix/redox-system/modules/build/root-tree.nix` — include activation scripts in rootTree
- `nix/redox-system/modules/build/manifest.nix` — track activation scripts in manifest
- `snix-redox/src/activate.rs` — execute activation scripts during switch
- `snix-redox/src/system.rs` — activation script metadata in manifest schema
- Test profiles and checks updated
