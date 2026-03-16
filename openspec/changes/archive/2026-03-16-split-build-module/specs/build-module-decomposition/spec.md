## ADDED Requirements

### Requirement: Build module decomposes into focused files
The build module SHALL be split into separate `.nix` files under `nix/redox-system/modules/build/`, where each file owns exactly one concern. The orchestrator `default.nix` SHALL import them and wire inputs to outputs.

#### Scenario: File inventory after split
- **WHEN** the split is complete
- **THEN** `nix/redox-system/modules/build/` SHALL contain: `default.nix`, `config.nix`, `assertions.nix`, `generated-files.nix`, `init-scripts.nix`, `pcid.nix`, `root-tree.nix`, `initfs.nix`, `checks.nix`, `manifest.nix`

#### Scenario: Orchestrator size
- **WHEN** the split is complete
- **THEN** `default.nix` SHALL be under 350 lines (imports, input wiring, output attrset)

### Requirement: Public interface is unchanged
The `build.impl` function SHALL return the same attrset shape as before: `{ rootTree, initfs, diskImage, toplevel, espImage, redoxfsImage, systemChecks, version, vmConfig }`. No attribute added, removed, or renamed.

#### Scenario: Output attributes preserved
- **WHEN** any profile is evaluated (minimal, graphical, functional-test, development, self-hosting, etc.)
- **THEN** `nix eval .#<profile>.build` SHALL produce the same attribute names as the pre-split version

#### Scenario: Disk image bit-identity
- **WHEN** a profile is built before and after the split with no other changes
- **THEN** the `rootTree` derivation SHALL produce identical output (same store hash)

### Requirement: config.nix computes shared configuration
`config.nix` SHALL be a function taking `{ lib, inputs, pkgs, redoxLib }` and returning an attrset containing all computed feature flags, package partitions, daemon lists, directory lists, and user info currently in the top section of `default.nix`.

#### Scenario: Config attrset contents
- **WHEN** `config.nix` is imported with valid inputs
- **THEN** it SHALL provide at minimum: `graphicsEnabled`, `networkingEnabled`, `usbEnabled`, `audioEnabled`, `allDrivers`, `bootPackages`, `managedPackages`, `allPackages`, `allDaemons`, `allDirectories`, `defaultUser`, `userutilsInstalled`, `hasSelfHosting`, `hasBinaryCache`

#### Scenario: Config does not create derivations
- **WHEN** `config.nix` is evaluated
- **THEN** it SHALL NOT create any derivations (no `runCommand`, `mkDerivation`, `writeText` calls) — it produces pure data only

### Requirement: assertions.nix validates cross-module invariants
`assertions.nix` SHALL be a function taking the config attrset and module inputs, returning `{ assertions, warnings, assertionCheck, warningCheck }` with the same validation logic as today.

#### Scenario: Failed assertion halts eval
- **WHEN** `graphics.enable = true` but no `orbital` package exists
- **THEN** `assertionCheck` SHALL throw with a message containing "graphics.enable requires the 'orbital' package"

#### Scenario: Warning traces without failing
- **WHEN** `graphics.enable = true` and `hardware.audioEnable = false`
- **THEN** `warningCheck` SHALL `builtins.trace` a warning about audio but NOT throw

### Requirement: generated-files.nix produces file content attrset
`generated-files.nix` SHALL return the `allGeneratedFiles` attrset mapping file paths to `{ text, mode }` or `{ source, mode }` entries. It SHALL NOT create derivations — only data.

#### Scenario: Profile file generation
- **WHEN** evaluated with hostname "redox" and timezone "UTC"
- **THEN** the returned attrset SHALL contain `"etc/profile"` with text containing `export HOSTNAME redox` and `export TZ UTC`

#### Scenario: Conditional networking files
- **WHEN** `networkingEnabled = true` and mode is "dhcp"
- **THEN** the attrset SHALL contain `"etc/net/dns"`, `"etc/net/ip_router"`, and `"bin/dhcpd-quiet"`
- **WHEN** `networkingEnabled = false`
- **THEN** the attrset SHALL NOT contain `"etc/net/dns"`

### Requirement: init-scripts.nix renders init.d scripts and services
`init-scripts.nix` SHALL return `{ initScriptFiles, allInitScriptsWithServices }` containing the numbered initfs init.d scripts and the merged raw+structured service init scripts for rootfs.

#### Scenario: Graphics init scripts present when enabled
- **WHEN** `initfsEnableGraphics = true`
- **THEN** `initScriptFiles."20_graphics"` SHALL contain "vesad" and "inputd"

#### Scenario: Service rendering
- **WHEN** a structured service of type "scheme" with command "zerod" and args "zero" is defined
- **THEN** `allInitScriptsWithServices` SHALL contain an entry with text "scheme zero zerod"

### Requirement: pcid.nix owns PCI driver registry
`pcid.nix` SHALL be a function taking `{ lib, allDrivers }` and returning `{ pciRegistry, pcidDrivers, pcidToml }`.

#### Scenario: Known driver produces TOML entry
- **WHEN** `allDrivers` contains "ahcid"
- **THEN** `pcidToml` SHALL contain a `[[drivers]]` block with `class = 1`, `subclass = 6`, and `command = ["/scheme/initfs/lib/drivers/ahcid"]`

#### Scenario: Unknown driver produces no entry
- **WHEN** `allDrivers` contains "unknownd" which is not in `pciRegistry`
- **THEN** `pcidToml` SHALL NOT contain a `[[drivers]]` block for "unknownd" (no crash, no entry)

### Requirement: Rust tool replaces Python ELF patcher
A Rust host package `fix-elf-palign` SHALL replace the inline Python ELF patcher. It SHALL walk a directory tree, find ELF files (`.so`, `.so.6`, `rustc`, `rustdoc`), and patch any 64-bit little-endian program header with `p_align=0` to `p_align=1`. It SHALL skip symlinks. It takes a root directory path as a CLI argument.

#### Scenario: Patches p_align=0 in .so files
- **WHEN** run on a directory containing a 64-bit ELF `.so` file with a PT_GNU_STACK header where `p_align=0`
- **THEN** the tool SHALL rewrite that header's `p_align` to `1` in-place and print a count of fixed files

#### Scenario: Skips non-ELF files
- **WHEN** run on a directory containing `.txt`, `.toml`, and shell scripts
- **THEN** the tool SHALL not modify any files and print no fix count

#### Scenario: Skips symlinks
- **WHEN** a `.so` symlink points to an ELF file with `p_align=0`
- **THEN** the tool SHALL skip the symlink (the real file may be patched if it matches the filename filter)

### Requirement: Rust tool replaces Python manifest hasher
A Rust host package `hash-manifest` SHALL replace the inline Python BLAKE3 manifest hasher. It SHALL read a base `manifest.json` from `<root>/etc/redox-system/manifest.json`, walk the root tree computing BLAKE3 hashes of regular files, compute a buildHash from the sorted inventory, write the final manifest, and seed `<root>/etc/redox-system/generations/1/manifest.json`. It takes a root directory path as a CLI argument.

#### Scenario: Computes file hashes and buildHash
- **WHEN** run on a root tree with files and a base `manifest.json`
- **THEN** the manifest SHALL contain a `"files"` key with BLAKE3 hex hashes, sizes, and octal modes for each file, and `"generation"."buildHash"` SHALL be the BLAKE3 hex hash of the sorted file inventory JSON

#### Scenario: Skips excluded paths
- **WHEN** the root tree contains files under `nix/store/`, `etc/redox-system/generations/`, and `etc/redox-system/manifest.json`
- **THEN** those paths SHALL NOT appear in the `"files"` inventory

#### Scenario: Skips symlinks
- **WHEN** the root tree contains symlinks
- **THEN** symlinks SHALL NOT appear in the `"files"` inventory

#### Scenario: Seeds generation 1
- **WHEN** `hash-manifest` completes
- **THEN** `<root>/etc/redox-system/generations/1/manifest.json` SHALL exist and contain the same content as the final `<root>/etc/redox-system/manifest.json`

### Requirement: rootTree has no Python dependency
The `rootTree` derivation SHALL NOT include Python in `nativeBuildInputs`. It SHALL invoke `fix-elf-palign` and `hash-manifest` as Rust binaries passed via `nativeBuildInputs`.

#### Scenario: nativeBuildInputs contains no python
- **WHEN** `rootTree` is built
- **THEN** its `nativeBuildInputs` SHALL include `fix-elf-palign` and `hash-manifest` but SHALL NOT include any `python3` package

### Requirement: root-tree.nix builds the rootTree derivation
`root-tree.nix` SHALL be a function that takes config, generated files, init scripts, binary cache, and self-hosting info, and returns the `rootTree` derivation. It SHALL invoke `fix-elf-palign` and `hash-manifest` as Rust binaries from `nativeBuildInputs`.

#### Scenario: ELF fixer invoked as Rust binary
- **WHEN** `rootTree` is built with `hasSelfHosting = true`
- **THEN** the build script SHALL call `fix-elf-palign $out` (from PATH via nativeBuildInputs)

#### Scenario: Manifest hasher invoked as Rust binary
- **WHEN** `rootTree` is built
- **THEN** the build script SHALL call `hash-manifest $out` (from PATH via nativeBuildInputs)

### Requirement: initfs.nix builds the initfs derivation
`initfs.nix` SHALL be a function taking `{ hostPkgs, pkgs, lib, config, initScriptFiles, pcidToml }` and returning the `initfs` derivation with the same structure as today.

#### Scenario: Initfs contains all core daemons
- **WHEN** built with default config
- **THEN** `initfs/bin/` SHALL contain `init`, `logd`, `pcid`, `pcid-spawner`, `ptyd`, `ipcd`, `lived`, `randd`, `zerod`, `hwd`, `rtcd`, `acpid`

#### Scenario: USB daemons included when USB enabled
- **WHEN** `usbEnabled = true`
- **THEN** `initfs/lib/drivers/` SHALL contain `xhcid`, and `initfs/bin/` SHALL contain `usbhubd`, `usbhidd`

### Requirement: checks.nix validates the rootTree
`checks.nix` SHALL be a function taking `{ hostPkgs, lib, rootTree, config }` and returning the `systemChecks` derivation with the same validation logic as today.

#### Scenario: Missing essential file fails check
- **WHEN** `rootTree` is missing `etc/passwd`
- **THEN** the `systemChecks` derivation SHALL fail with a message containing "Missing essential file"

### Requirement: manifest.nix produces version and toplevel
`manifest.nix` SHALL return `{ versionInfo, versionJson, manifestData, manifestJson, toplevel }`. The `toplevel` derivation SHALL link to all system components and force `systemChecks`.

#### Scenario: Toplevel links all components
- **WHEN** `toplevel` is built
- **THEN** it SHALL contain symlinks: `root-tree`, `initfs`, `kernel`, `bootloader`, `disk-image`, `checks`, `etc`, `version.json`
