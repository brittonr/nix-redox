# Alpha release readiness

This repo is alpha-ready only when a candidate commit has passing evidence for the supported paths below and the known experimental paths are called out clearly.

## Alpha scope

Supported for alpha:

- Host: `x86_64-linux` with Nix flakes enabled and KVM available.
- Primary boot path: `nix run .#graphical` for QEMU graphical desktop.
- Fast headless path: `nix run .#headless` / `nix run .#run-redox-minimal` for serial-console work.
- Build outputs: `nix build`, `nix build .#diskImage`, and `nix build .#redox-self-hosting`.
- On-guest management: `snix system rebuild`, generations, rollback, package install/remove, and binary-cache bridge flows covered by VM tests.

Experimental for alpha:

- Bare-metal profiles, including GMKtec/LattePanda/N100 bring-up.
- I225/I226 networking and netcfg autoconfiguration outside validated hardware runs.
- Vendored-crate cleanup, native C/C++ gauntlet expansion, and CA-bundle unification work tracked in OpenSpec changes.
- `aarch64-linux` flake outputs unless a release candidate is explicitly validated on that host.

## Required validation gates

Run from repo root on the candidate commit:

```bash
nix run .#test-quick
nix run .#test-host
nix run .#test-cross
nix run .#test-vm
```

For a tag candidate, also run the heavy proof paths that match touched areas:

```bash
nix run .#snix-sandbox-test -- --verbose
nix run .#snix-compile-test -- --verbose
nix run .#self-hosting-test -- --verbose
nix run .#kernel-rebuild-test -- --verbose
```

Use `nix flake check` as the final aggregate gate when time allows. It includes all flat checks plus package/app/devshell validation and can take much longer than the tiered apps. If teeing logs, run it under `bash -o pipefail -c 'nix flake check 2>&1 | tee ...'` so a failing check cannot be hidden by `tee`.

## Evidence handling

- Long VM proof wrappers write durable artifacts under `/var/tmp/redox-self-hosting-captures/<run-id>/`.
- Successful proof wrappers refresh `docs/self-hosting/latest-success.md` and `docs/self-hosting/latest-success.json`.
- Keep pueue logs only as convenience output; copy important excerpts into durable capture dirs or docs.
- A release candidate is not ready if the latest success doc points at an older commit for a touched proof path.

## Release checklist

Before tagging alpha:

- [ ] Worktree clean except intentionally ignored local files.
- [ ] README commands match current flake apps and packages.
- [ ] `docs/self-hosting/latest-success.md` lists current-candidate proof runs for touched heavy paths.
- [ ] `nix run .#test-quick` passes.
- [ ] `nix run .#test-host` passes.
- [ ] `nix run .#test-cross` passes.
- [ ] `nix run .#test-vm` passes.
- [ ] Heavy proof paths above pass when their subsystems changed.
- [ ] Known experimental paths are listed in release notes instead of implied stable.
- [ ] Binary cache / artifact publishing notes include exact store paths or cache status output.

## Known alpha limitations

- Full self-hosting proof can run for hours and may be quiet while compiling; rely on heartbeat/capture artifacts.
- Redox Ion is not POSIX shell; user docs and examples must avoid POSIX-only syntax unless explicitly using bash.
- Bare-metal support is hardware-specific and should ship as experimental unless a board has fresh boot/login/input/network evidence.
- Remote HTTPS/cache behavior depends on CA bundle handling and should stay documented as tested only by the relevant VM proof.
