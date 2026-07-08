# Validation evidence: Redox substrate build reproducibility

Date: 2026-07-08

## Baseline

```text
nix build .#initfsTools -L --no-link
```

Result: pueue task 15 failed before implementation with the stale fixed-output source hash:

```text
specified: sha256-hhd13ybzMKUHxgEBcbKxzEzPSneSDi/u6M2XZ0L7dWI=
got:       sha256-BJCdk2oFEZZeqIUbTiqpP9gWMaA1WSOOVEpyXAQZrtQ=
```

## Implemented surfaces

- Updated `nix/pkgs/infrastructure/initfs-tools.nix` source hash to `sha256-BJCdk2oFEZZeqIUbTiqpP9gWMaA1WSOOVEpyXAQZrtQ=`.
- Updated `initfsToolsVendor` hash to `sha256-FSOjnh/oTVO9XFw0UfmOfAfSvo9+tTdmnYjlBhgaiMM=`.
- Added repo-owned public substrate VM proof fixture:
  - `examples/substrate-vm-proof/primitive-plan.nix`
  - `examples/substrate-vm-proof/default.nix`
- Added package outputs:
  - `redox-substrate-vm-proof`
  - `redox-substrate-vm-proof-disk`
  - `redox-substrate-vm-proof-initfs`
  - `redox-substrate-vm-proof-root-tree`
  - `run-redox-substrate-vm-proof-qemu`
- Added substrate tests for proof artifact planning and the initfs-tools fixed-output/cacert regression guard.
- Updated `docs/redox-substrate.md` with the manual proof command, output names, cleanup boundary, and non-claims.

## Formatting

```text
nixfmt nix/pkgs/infrastructure/initfs-tools.nix nix/flake-modules/system.nix nix/tests/substrate.nix examples/substrate-vm-proof/default.nix examples/substrate-vm-proof/primitive-plan.nix
```

Result: `nixfmt-rs` completed successfully.

## Focused checks

```text
nix build .#initfsTools -L --no-link
```

Result: pueue task 21 passed without `NIX_SSL_CERT_FILE` or other shell certificate overrides.

```text
nix build \
  .#checks.x86_64-linux.substrate-vm-proof-artifact-plan-from-public-surface \
  .#checks.x86_64-linux.substrate-initfs-tools-fixed-output-fetches-own-cacert \
  .#checks.x86_64-linux.substrate-fixture-builds-from-public-surface \
  .#checks.x86_64-linux.substrate-rejects-private-consumer-import \
  --no-link -L
```

Result: pueue task 31 passed. The two new checks printed `Test PASSED`.

```text
nix build .#redox-substrate-vm-proof -o /tmp/redox-substrate-vm-proof-result -L
```

Result: pueue task 52 passed. Output contains `disk.img`, `initfs`, `kernel`, `redoxfs.img`, `run-redox-qemu`, and `README.txt`.

```text
/tmp/redox-substrate-vm-proof-result/run-redox-qemu
```

Result: pueue task 61 ran the headless QEMU runner, captured `ONIXOS_REDOX_VM_RECEIPT_JSON=...`, and terminated QEMU after marker capture. Receipt fields included `machine = redoxvm`, `substrate = redox`, materialization refs `export/initfs`, `export/kernel`, `export/redoxfs.img`, `runtime_owned = true`, and `nix_runtime_fallback = false`.

```text
nix build .#checks.x86_64-linux.tier-eval --no-link -L
```

Result: pueue task 63 passed.

## Notes

- An initial attempt to build the proof export through the default full substrate package set pulled in self-hosting sysroot/LLVM dependencies. The final proof target uses a minimal proof-specific substrate instance while still consuming the same public substrate interface and checked-in primitive plan.
- Real QEMU execution remains manual/opt-in and is not claimed as deploy, activation, physical install, rollback, power-loss, or broad OnixOS lifecycle support.
