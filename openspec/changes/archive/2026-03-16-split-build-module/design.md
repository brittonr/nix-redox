## Context

`nix/redox-system/modules/build/default.nix` is the sole build module in the adios module system. It reads inputs from 16 other modules (`/pkgs`, `/boot`, `/hardware`, `/networking`, etc.) and produces 7 outputs: `rootTree`, `initfs`, `diskImage`, `toplevel`, `espImage`, `redoxfsImage`, `systemChecks`, plus `version` and `vmConfig`.

Internally it's a single 2007-line `let ... in { }` block containing:
- ~150 lines of computed config (feature flags, package partitioning, user/directory collection)
- ~100 lines of assertions and warnings
- ~200 lines of generated file content (profile, passwd, shadow, init scripts, security, networking, logging, power, programs configs)
- ~60 lines of PCI driver registry and pcid.toml rendering
- ~100 lines of initfs init.d script definitions
- ~80 lines of structured service rendering
- ~150 lines of shell helpers for rootTree assembly (mkDirs, mkBootPackages, mkStorePackages, etc.)
- ~200 lines of rootTree derivation (including inline Python for ELF p_align patching and BLAKE3 manifest hashing)
- ~100 lines of systemChecks derivation
- ~80 lines of initfs derivation
- ~50 lines of manifest/version data structures
- ~50 lines of disk image composition (imports existing lib/ builders)
- ~80 lines of toplevel derivation

The file has grown additively — each new module option adds generated files, init scripts, and assertions here. The inline Python (ELF fixer, manifest hasher) and shell (package copying, symlink creation) are heredocs inside Nix `''` strings, making them hard to lint, test, or edit independently.

## Goals / Non-Goals

**Goals:**
- Split the monolith into files under `nix/redox-system/modules/build/` where each file owns one concern
- Replace inline Python with small Rust tools built as host packages — no Python dependency in rootTree
- Keep the public interface unchanged — `build.impl` returns the same attrset
- Keep the adios module structure unchanged — `build/default.nix` stays the module entry point
- Make it possible to evaluate/test sub-components in isolation (e.g., `nix eval` the PCI registry)

**Non-Goals:**
- Changing the adios module system itself or how inputs/outputs work
- Refactoring the other 16 input modules
- Changing any generated file content, init script ordering, or package layout
- Adding new features or changing build outputs
- Splitting infrastructure scripts (cloud-hypervisor-runners, mk-vm-test, redox-rebuild)

## Decisions

### 1. File decomposition into `build/` subdirectory

The `build/` directory already exists (it contains `default.nix`). New files go alongside it as regular Nix files imported by `default.nix`. No new adios modules — these are internal implementation files.

**Layout:**
```
nix/redox-system/modules/build/
├── default.nix          # Orchestrator: imports, wires inputs → outputs (~250 lines)
├── config.nix           # Computed config: feature flags, package partitioning, user/dir collection
├── assertions.nix       # Assertions and warnings
├── generated-files.nix  # All /etc/ file content generation
├── init-scripts.nix     # Numbered initfs scripts + structured service rendering
├── pcid.nix             # PCI driver registry + pcid.toml generation
├── root-tree.nix        # rootTree derivation (shell helpers + assembly)
├── initfs.nix           # initfs derivation
├── checks.nix           # systemChecks derivation
└── manifest.nix         # Version info, manifest JSON, toplevel derivation
```

Plus two Rust tool packages under `nix/pkgs/host/`:
```
nix/pkgs/host/
├── fix-elf-palign.nix   # Rust tool: patch ELF p_align=0 → 1
└── hash-manifest.nix    # Rust tool: BLAKE3 manifest hashing + generation seeding
```

**Alternative considered:** Flat files in `modules/` (e.g., `modules/build-root-tree.nix`). Rejected because they'd pollute the module namespace — adios auto-discovers `.nix` files in `modules/` and treating them as modules would break.

### 2. Each file is a function taking a config attrset

Each extracted file exports a function that takes what it needs and returns what it produces. The orchestrator (`default.nix`) calls each with the relevant subset of computed values.

```nix
# pcid.nix
{ lib, allDrivers }:
{
  pcidDrivers = ...;
  pcidToml = ...;
  pciRegistry = ...;
}

# default.nix imports and calls:
pcid = import ./pcid.nix { inherit lib allDrivers; };
```

This avoids a shared "context" attrset that recreates the monolith problem. Each file declares exactly what it reads.

**Alternative considered:** Making each file an adios sub-module. Rejected because adios modules have typed options/inputs/impl structure — overkill for internal decomposition, and would require 8 new module registrations.

### 3. Rust tools replace inline Python

Two small Rust crates built as host packages replace the Python heredocs:

**`fix-elf-palign`** — walks a directory tree, finds ELF files (`.so`, `.so.6`, `rustc`, `rustdoc`), patches any program header with `p_align=0` to `p_align=1`. Uses raw byte manipulation (no ELF library needed — it's 64-bit little-endian only, same as the Python). Takes a root directory as CLI arg.

**`hash-manifest`** — reads a base `manifest.json`, walks the root tree computing BLAKE3 hashes of each file (skipping the manifest itself, generation copies, nix/store/, and symlinks), computes a buildHash from the sorted inventory, writes the final manifest and seeds generation 1. Uses `blake3`, `serde_json`, `walkdir` crates. Takes a root directory as CLI arg.

Both are host-only tools (run at build time on the build machine, not on Redox). They go in `nix/pkgs/host/` alongside `redoxfs.nix`, `cookbook.nix`, `installer.nix`.

The rootTree derivation drops `python3` from `nativeBuildInputs` and calls `${fix-elf-palign}/bin/fix-elf-palign $out` and `${hash-manifest}/bin/hash-manifest $out` instead.

The final status line (`echo "Manifest: ..."`) that currently shells out to `python3 -c` switches to `hash-manifest` printing its own summary, or a simple `wc -l` on the manifest.

**Alternative considered:** Standalone `.py` files called by the derivation. Rejected — user wants Rust and Nix only, no Python in the build pipeline.

**Alternative considered:** Pure bash/Nix for hashing. Rejected — BLAKE3 has no coreutils equivalent, and ELF binary patching in bash would be grotesque.

### 4. Shared computed config via `config.nix`

The top ~150 lines of `default.nix` that compute feature flags, package lists, daemon lists, directory lists, and user info move to `config.nix`. This returns an attrset that `default.nix` passes (or subsets of) to each file.

```nix
# config.nix
{ lib, inputs, pkgs, redoxLib }:
{
  graphicsEnabled = ...;
  networkingEnabled = ...;
  allDrivers = ...;
  bootPackages = ...;
  managedPackages = ...;
  allPackages = ...;
  allDirectories = ...;
  defaultUser = ...;
  userutilsInstalled = ...;
  # ...
}
```

This is the spine — every other file depends on some subset of it.

### 5. Validation order: assertions before any derivation

`assertions.nix` returns `{ assertionCheck, warningCheck, assertions, warnings }`. The orchestrator threads `assertionCheck` and `warningCheck` into `rootTree` via `assert`, same as today. No change in eval-time failure behavior.

### 6. Generated files as a pure attrset

`generated-files.nix` returns the `allGeneratedFiles` attrset (path → `{ text, mode }` or `{ source, mode }`). No derivations — just data. The `root-tree.nix` derivation consumes it and writes files. This makes it trivial to `nix eval` the generated file list without building anything.

## Risks / Trade-offs

**[Two new Rust crates to maintain]** → Each is <100 lines with no complex dependencies. `fix-elf-palign` is pure byte manipulation, `hash-manifest` is walk+hash+json. The Rust versions are more robust than the Python (type safety, proper error handling) and can be tested with `cargo test`. Worth the initial setup cost.

**[Many small files vs. one big file]** → Ten `.nix` files instead of one. Navigation requires knowing which file owns what. Mitigated by clear naming and each file having a single responsibility documented in its header comment.

**[Import overhead]** → Nix `import` is cached per-eval, so 8 imports have negligible cost. Not a real risk.

**[Cross-file refactoring]** → Renaming a config field now requires updating `config.nix` and every consumer. Mitigated by `nix eval` catching undefined attributes at eval time (fast feedback).

**[Heredoc indentation]** → Moving init scripts to `init-scripts.nix` could change indentation context. Mitigated by testing that `nix build .#functional-test` and `nix build .#graphical` produce byte-identical disk images before and after.

**[New file tracking]** → New `.nix` files must be `git add`ed for flake visibility. Mitigated by adding to the same commit as the code that references them.
