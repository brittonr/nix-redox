## Why

`nix flake check` runs only 4 of 17 VM tests (boot, functional, multi-user, bridge). The other 13 test packages build and run fine via `nix run` but aren't wired into the check tier system. A CI run that passes tier-vm gives false confidence — networking, scheme daemons, rebuild pipelines, and self-hosting all go untested.

## What Changes

- Restructure tier-vm in `checks.nix` into sub-tiers by cost and requirements:
  - **tier-vm-fast**: Current 4 tests + 4 quick offline tests (scheme-daemon, iroh, scheme-native, boot-generation-select). Under 3 minutes each.
  - **tier-vm-full**: Adds medium-duration offline tests (rebuild-generations, e2e-rebuild) and QEMU SLiRP network tests (network, network-install, channel-update). 5-10 minutes each.
  - **tier-vm-heavy**: Self-hosting (1500s), parallel-build (1800s), bridge-rebuild. 15-30 minutes each.
- Keep existing `tier-vm` as an alias for `tier-vm-fast` so current workflows don't break.
- Add `tier-vm-all` that depends on all three sub-tiers.
- `httpsCacheTest` stays out — requires internet access incompatible with Nix build sandbox.

## Capabilities

### New Capabilities
- `vm-test-tiers`: Sub-tier organization of VM tests in checks.nix with fast/full/heavy groupings and aggregation targets.

### Modified Capabilities

## Impact

- `nix/flake-modules/checks.nix`: Add 13 test packages to vmChecks, restructure tier-vm into sub-tiers.
- `nix flake check` execution time: tier-vm-fast stays similar to current; tier-vm-all adds significant time.
- No changes to test scripts, profiles, or packages — this is pure wiring.
