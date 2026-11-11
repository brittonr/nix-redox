# `redox-rebuild` host-side system management

`redox-rebuild` is the host-side configuration manager for this repository. It
builds Redox system configurations, records generations, and launches the
profile runners. It is modeled after `nixos-rebuild` and `darwin-rebuild`, but
the target is a VM image rather than the host OS.

## Commands

```bash
nix run .#redox-rebuild -- build                  # build default and record a generation
nix run .#redox-rebuild -- switch graphical       # build and select a new generation
nix run .#redox-rebuild -- boot                   # alias for switch
nix run .#redox-rebuild -- run graphical          # build and launch the VM
nix run .#redox-rebuild -- test graphical -- --verbose
nix run .#redox-rebuild -- diff                   # compare the build with the current generation
nix run .#redox-rebuild -- check                  # assertions and system checks only
nix run .#redox-rebuild -- list-generations
nix run .#redox-rebuild -- rollback               # select the previous generation
nix run .#redox-rebuild -- rollback 2             # select a specific generation
nix run .#redox-rebuild -- version
nix run .#redox-rebuild -- repl
```

`--dry-run` works with `build`, `switch`, and `boot`: it prints the Nix build
plan and exits without recording a generation.

Profiles: `default`, `minimal`, `graphical`, and `cloud`.

## Generations

State lives in `.redox-generations/` in the working directory by default:

```text
.redox-generations/
  system -> /nix/store/...-redox-...-toplevel
  system-1-link -> /nix/store/...
  system-2-link -> /nix/store/...
```

The links are GC roots. Set `REDOX_GENERATIONS` to keep them elsewhere.
`list-generations --json` returns machine-readable metadata. `rollback`
changes the `system` link without deleting older generations.

## Boundary with in-guest updates

`redox-rebuild` manages **host-side builds and image generations**. It does not
hot-swap a running guest. For live changes inside a booted system use:

```bash
snix system rebuild
snix system switch --rollback
snix system generations
```

`redox-rebuild run` builds the selected profile and launches it through the
normal graphical or headless runner. `redox-rebuild diff` compares top-level
metadata and root-tree file lists between the current generation and a fresh
build.

## Options

```text
--flake PATH           flake to evaluate (default: .)
--profile-name, -p N   internal profile name (default: system)
--verbose, -v          show Nix build logs
--show-trace           pass --show-trace to Nix
--json                 JSON output for list-generations and version
--dry-run              plan only for build/switch/boot
```
