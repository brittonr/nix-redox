## Why

The Redox module system (adios-based) already mirrors nix-darwin's structure — typed modules, profiles, services, users, activation. But the flake integration surface is ad-hoc: system configurations live under `legacyPackages`, there's no downstream flake-module, no templates, and the toplevel derivation is passive metadata rather than an activatable system. Adopting nix-darwin's integration patterns (while keeping adios) makes Redox a first-class Nix citizen — discoverable, composable, and familiar to anyone who's used NixOS or nix-darwin.

## What Changes

- Export `lib.redoxSystem` and `redoxConfigurations` as top-level flake outputs (like `darwinConfigurations`)
- Ship a `flakeModules.default` so downstream flakes can declare Redox systems via flake-parts/adios-flake
- Ship a `templates.default` for `nix flake init -t redox`
- Restructure `toplevel` to include an embedded `activate` script (like nix-darwin's `$systemConfig/activate`)
- Build a standalone `/etc` derivation and wire activation to use `/etc/static` symlink indirection
- Add `system.stateVersion` option for forward-compatible migration
- Add auto-generated options documentation (`packages.optionsJSON`)
- Add GC root management to activation (`/nix/var/nix/gcroots/current-system`)

## Capabilities

### New Capabilities
- `flake-integration`: Top-level `lib.redoxSystem`, `redoxConfigurations` flake output, `flakeModules.default`, and `templates.default`
- `activatable-toplevel`: Toplevel derivation with embedded `activate` script, `/etc/static` symlink farm, GC root management
- `options-documentation`: Auto-generated JSON/Markdown option reference from adios module descriptions
- `state-version`: `system.stateVersion` option for config migration guards

### Modified Capabilities

## Impact

- `flake.nix`: New top-level outputs (`lib`, `redoxConfigurations`, `flakeModules`, `templates`)
- `nix/flake-modules/system.nix`: Expose `redoxConfigurations` alongside packages
- `nix/redox-system/modules/build/manifest.nix`: Restructure toplevel with activate script
- `nix/redox-system/modules/build/generated-files.nix`: Extract standalone etc derivation
- `nix/redox-system/modules/system.nix`: Add stateVersion option
- New files: `flake-module.nix`, `templates/default/`, options doc generator
- No breaking changes — existing `packages.*` and `legacyPackages.*` remain
