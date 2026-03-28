## Context

The Redox flake currently exposes system configurations under `legacyPackages.redoxConfigurations` and `legacyPackages.mkRedoxSystem`. The toplevel derivation is a passive store path with symlinks and metadata — there's no activate script. Configuration files are baked into rootTree at build time with no runtime update mechanism. Downstream flakes have no standard way to declare Redox systems.

nix-darwin solves all of these for macOS. We adopt their integration patterns while keeping adios as the module evaluation engine.

## Goals / Non-Goals

**Goals:**
- Make Redox a first-class flake citizen (lib, configurations, flake-module, templates)
- Give `snix system switch` a real activation target (toplevel with activate script)
- Enable etc file updates without rebuilding rootTree
- Generate option docs from existing module descriptions
- Add stateVersion for future migration safety

**Non-Goals:**
- Replace adios with lib.evalModules
- Change how profiles or modules are authored
- Modify the existing package build pipeline
- Add runtime service management (restart/reload detection) — future work

## Decisions

### 1. Flake output structure

Export `lib.redoxSystem` at the flake top level via the `flake` attrset in `adios-flake.lib.mkFlake`. Export `redoxConfigurations` similarly. This mirrors nix-darwin's `lib.darwinSystem` + `darwinConfigurations`.

The existing `packages.*` and `legacyPackages.*` stay untouched — `redoxConfigurations` is additive.

Alternative: Put everything under `legacyPackages` — rejected because it's not discoverable by `nix flake show` and doesn't match ecosystem conventions.

### 2. flakeModules.default

A minimal nix file that defines `flake.redoxConfigurations` as a `lib.types.lazyAttrsOf lib.types.raw` option, matching exactly what nix-darwin's `flake-module.nix` does for `darwinConfigurations`. No evaluation logic — just schema declaration for flake-parts consumers.

### 3. Toplevel restructuring

The current `manifest.nix` toplevel becomes an activatable derivation. New layout:

```
$out/
  activate           # Shell script (Ion or bash via /nix/system/profile/bin/bash)
  etc/               # Standalone etc symlink farm
  root-tree          # → rootTree
  initfs             # → initfs
  kernel             # → kernel
  bootloader         # → bootloader
  disk-image         # → diskImage
  version.json
  system             # target triple
  name               # profile name
  nix-support/
    build-info
```

The `activate` script is generated in `manifest.nix` as a `writeScript` derivation embedded into toplevel. It uses Ion shell (available on Redox) for the on-target activation steps.

Alternative: Generate activate as a Rust binary — rejected as overkill for symlink management. Shell script matches nix-darwin's approach.

### 4. Standalone etc derivation

`generated-files.nix` already produces `allGeneratedFiles`. We build a separate derivation from this attrset: one file per entry, text or source, with correct modes. This derivation is linked into toplevel at `$out/etc/`.

The rootTree still gets the same files baked in for the initial disk image. The etc derivation is the diff-friendly, activation-switchable form.

### 5. /etc/static symlink pattern

On activation:
1. `ln -sfn $toplevel/etc /etc/static`
2. For each file in `/etc/static`, create `/etc/foo → /etc/static/foo`
3. Remove stale symlinks that pointed to old `/etc/static` entries

This matches nix-darwin's `system.activationScripts.etc.text`. No conflict detection initially (Redox doesn't have user-edited etc files yet). Can add later when needed.

### 6. GC root

Activation creates:
```
/nix/var/nix/gcroots/current-system → /run/current-system → $toplevel
```

Simple, matches nix-darwin exactly.

### 7. Options documentation generator

A Nix derivation that:
1. Loads the adios module tree (without evaluating — just the option definitions)
2. Walks each module's `options` attrset recursively
3. Extracts `type`, `default`, `description` for each option
4. Writes JSON and renders Markdown

This is a `hostPkgs.runCommand` that uses `nix eval` or a small Nix expression to serialize the option tree. The adios types have `.name` fields from korora that give us type names.

### 8. stateVersion

A simple integer option in `/system`. The build module's `config.nix` reads it. Guard pattern:

```nix
defaultFoo = if stateVersion < 2 then "old" else "new";
```

No migration logic now — just the plumbing so we can add guards as needed.

### 9. Template

A `templates/default/` directory containing:
- `flake.nix` — imports the Redox flake, calls `lib.redoxSystem`
- `configuration.nix` — documented profile with commented-out options

Matches nix-darwin's `modules/examples/flake/` template.

## Risks / Trade-offs

- **[Activate script on Redox]** The activate script runs on Redox, so it must use Ion or bash-via-nix. If bash isn't installed, Ion is the only option. Ion's limitations (no heredocs, `$()` crashes on empty) constrain the script. → Mitigation: Keep the script minimal — just symlink management and script execution. Complex logic belongs in the Rust `snix` binary that calls activate.

- **[etc/static on initial boot]** The first boot from a fresh disk image has files baked into rootTree, not symlinked through /etc/static. The activate script must handle the transition from baked-in to symlinked. → Mitigation: First activation detects missing /etc/static and creates it. Existing baked-in files are replaced with symlinks.

- **[Options doc completeness]** adios options use korora types whose names may not be self-documenting (e.g. `t.attrs` vs `lib.types.attrsOf lib.types.str`). → Mitigation: Map korora type names to readable strings in the generator.

## Open Questions

- Should the activate script be Ion or bash? Ion is always available but limited. Bash is available when self-hosting profile is active. Decision: use Ion for the activate script body — it's the guaranteed shell.
