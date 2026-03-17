## 1. environment.etc option

- [x] 1.1 Add `etc` option to `nix/redox-system/modules/environment.nix` — attrset of `{ text, source, mode }` structs with korora types, default `{}`
- [x] 1.2 Merge `environment.etc` entries into `allGeneratedFiles` in `generated-files.nix` — user entries applied after hardcoded files (override with `//`)
- [x] 1.3 Add `environment.etc` subdirectory creation to `allDirectories` in `config.nix` — extract parent dirs from etc entry keys
- [x] 1.4 Add unit tests for etc override behavior — profile sets `etc."etc/hostname"`, verify user entry wins over built-in

## 2. Activation module

- [x] 2.1 Create `nix/redox-system/modules/activation.nix` — adios module with `scripts` option (attrset of `{ text, deps }` structs), default `{}`
- [x] 2.2 Wire `/activation` input in `build/default.nix` — add to inputs map and pass to sub-modules
- [x] 2.3 Write activation scripts to rootTree at `etc/redox-system/activation.d/<name>` in `generated-files.nix` — mode 0755
- [x] 2.4 Add `activationScripts` field to manifest JSON in `manifest.nix` — array of `{ name, deps }` objects

## 3. Rust activation execution

- [x] 3.1 Add `ActivationScript` struct and `activationScripts` field to manifest schema in `system.rs`
- [x] 3.2 Implement topological sort with cycle detection in `activate.rs` — take `Vec<ActivationScript>`, return ordered names or cycle error
- [x] 3.3 Execute activation scripts in `activate()` after config file update step — read from `/etc/redox-system/activation.d/`, run in topo order, collect warnings on failure
- [x] 3.4 Add activation scripts to `ActivationPlan` display — show script names and execution order in dry-run output

## 4. Tests

- [x] 4.1 Add Nix build check for environment.etc — verify custom files appear in rootTree with correct content and mode
- [x] 4.2 Add Nix build check for activation scripts — verify scripts appear in rootTree at `etc/redox-system/activation.d/`
- [x] 4.3 Add Rust unit tests for topological sort — empty input, linear chain, diamond deps, cycle detection
- [x] 4.4 Add Rust unit tests for activation script plan display — scripts shown in dry-run output
- [x] 4.5 Create test profile that uses both features — `etc."etc/motd"` + activation script that creates a directory, verify in existing check framework
