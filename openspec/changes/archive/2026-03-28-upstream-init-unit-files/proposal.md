## Why

The upstream Redox `init` binary (base-src `ad371443f0fa`) replaced the shell-script init system with a systemd-like unit file format. Init now parses `.service` and `.target` TOML files instead of numbered shell scripts. Our init-scripts module still generates the old format, causing boot to stall with "unit 00_runtime.target not found" after the kernel/bootloader fixes land.

## What Changes

- **BREAKING**: Replace numbered shell init scripts (`00_runtime`, `90_exit_initfs`, etc.) with TOML unit files (`.service` and `.target`)
- Convert service rendering from `export KEY VALUE` / `scheme name cmd` / `notify cmd` shell lines to TOML `[unit]` + `[service]` sections
- Generate `.target` grouping files that declare `requires_weak` dependency lists instead of relying on numeric ordering
- Remove `run.d` and `switchroot` shell commands from init script text — the new init binary handles `switchroot` natively via `SwitchRoot` struct
- Update initfs assembly to write `.service`/`.target` files into `etc/init.d/` instead of extensionless shell scripts
- Adapt rootfs service files in `usr/lib/init.d/` to use the same TOML format
- Keep the module-owned service declaration API (`services.services`, `networking.services`, etc.) — only the rendering layer changes

## Capabilities

### New Capabilities
- `init-unit-files`: Generation of TOML-based `.service` and `.target` unit files compatible with the upstream init binary's `UnitStore` parser

### Modified Capabilities
- `declarative-services`: Service rendering output changes from shell script text to TOML unit file format. The module declaration API (type, command, args, environment, after, wantedBy) is preserved but the generated file format changes.

## Impact

- `nix/redox-system/modules/build/init-scripts.nix` — service rendering, initfs script generation, rootfs script generation
- `nix/redox-system/modules/build/initfs.nix` — writing unit files instead of shell scripts to `etc/init.d/`
- `nix/redox-system/modules/build/root-tree.nix` — rootfs `usr/lib/init.d/` files
- All profile configurations that declare `initScripts` overrides — must adapt to new format
- Functional test expectations — init output messages change
- Boot banner / env setup in `90_exit_initfs` — now handled by init's `SwitchRoot` which sets PATH/LD_LIBRARY_PATH automatically
