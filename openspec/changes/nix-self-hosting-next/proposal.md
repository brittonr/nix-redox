## Why

snix on Redox can evaluate Nix expressions, build derivations from `--expr`/`--file`, self-compile (193 crates), and build ripgrep (33 crates) — all through the local builder with per-path sandbox. But flake installable builds (`snix build .#package`) have never been validated in a VM, the `snix system rebuild` command can only resolve packages from a pre-built binary cache (no source compilation), builds involving C dependencies or Cargo workspace crates aren't tested on-guest, and `fetchGit` is a hard error. These four gaps block the path from "can compile Rust on Redox" to "can build and manage a Redox system from source on Redox."

## What Changes

- **Flake installable VM validation**: Add a VM test that exercises `snix build .#package` end-to-end on Redox — parse installable, resolve flake.lock inputs, fetch tarballs, evaluate, build, and produce a store output. Ship a minimal flake + flake.lock on the disk image so the test runs offline.
- **Source-based system rebuild**: Extend `snix system rebuild` with a `--source` mode that compiles packages from Nix expressions instead of resolving names against a binary cache index. This means evaluating a package set expression, building derivations locally, and activating the result — the Redox equivalent of `nixos-rebuild switch` from source.
- **Complex build support**: Validate and fix builds that involve C library dependencies (cc-rs build scripts, `-lz`, `-lexpat`, etc.) and Cargo workspace crates (multiple `[workspace.members]`) when compiled on-guest through `snix build`. Add VM tests for at least one C-dep crate and one workspace crate.
- **fetchGit builtin**: Implement `builtins.fetchGit` and the `git` locked input type in flake.rs, enabling flake inputs that use `git+https://` or `git+file://` references. Required for any flake whose lock file contains git-type inputs.

## Capabilities

### New Capabilities
- `flake-installable-vm-test`: VM test validating `snix build .#package` end-to-end on Redox with offline flake inputs
- `source-based-rebuild`: `snix system rebuild --source` mode that compiles packages from Nix expressions rather than binary cache lookup
- `complex-on-guest-builds`: On-guest builds of C-dependency crates and Cargo workspace crates through snix, with VM test coverage
- `fetchgit-builtin`: `builtins.fetchGit` implementation and git-type locked input resolution in flake.rs

### Modified Capabilities
- `nix-derivation-builds`: Extends local builder to handle C-dep and workspace builds (new sandbox allowances, CC wrapper integration)
- `upstream-fetchurl`: Extends fetcher infrastructure with git clone/checkout support

## Impact

- **snix-redox/src/flake.rs**: New `git` input type handler, test flake generation
- **snix-redox/src/fetchers.rs**: New `fetch_git` implementation (shell out to `git` or use libgit2-like approach)
- **snix-redox/src/rebuild.rs**: New `--source` flag, package-set evaluation, source build orchestration
- **snix-redox/src/local_build.rs**: Possible sandbox adjustments for C builds (cc-rs needs to invoke clang)
- **nix/redox-system/profiles/**: New VM test profiles for flake-installable and complex builds
- **nix/pkgs/infrastructure/**: Test flake source bundle for offline VM testing
- **Disk image size**: Source-based rebuild tests need larger images (source bundles + build artifacts)
