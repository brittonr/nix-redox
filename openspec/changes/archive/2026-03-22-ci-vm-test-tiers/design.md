## Context

`checks.nix` defines four check tiers: eval (seconds), host (minutes), cross (many minutes), vm (many minutes). The vm tier has 4 tests. There are 13 additional VM test packages already built and exposed in `system.nix` but not referenced from `checks.nix`. All use the same `mkVmTest` infrastructure and emit FUNC_TEST/NET_TEST protocol lines.

The tests vary widely in cost: scheme-daemon-test takes ~60s, self-hosting-test takes ~25 minutes. Lumping them into one tier means either running everything (too slow for iteration) or running nothing beyond the current 4.

## Goals / Non-Goals

**Goals:**
- Wire all offline-capable VM tests into `nix flake check`
- Sub-tier organization so developers can choose fast vs full vs heavy
- Keep `tier-vm` backward-compatible (alias to fast sub-tier)
- Provide `tier-vm-all` for full CI runs

**Non-Goals:**
- Modifying test scripts, profiles, or packages — pure wiring
- Adding httpsCacheTest (needs internet, incompatible with Nix sandbox)
- Changing the mkVmTest infrastructure
- Parallel VM execution within a tier (Nix handles parallelism)

## Decisions

### 1. Three sub-tiers by cost

**tier-vm-fast** (current + quick tests, <3 min each):
- boot-test, functional-test, multi-user-test, bridge-test (existing)
- scheme-daemon-test, iroh-test, scheme-native-test, boot-generation-select-test (new)

**tier-vm-full** (medium duration + networking, 3-10 min each):
- rebuild-generations-test (timeout 300s)
- e2e-rebuild-test (timeout 300s)
- network-test (QEMU SLiRP, 120s)
- network-install-test (SLiRP + host HTTP server, 120s)
- channel-update-test (SLiRP + host HTTP server, 120s)

**tier-vm-heavy** (expensive, 15-30 min each):
- bridge-rebuild-test (virtio-fs bridge rebuild)
- self-hosting-test (8GB RAM, 1500s timeout)
- parallel-build-test (4GB RAM, 1800s timeout)

**Rationale**: Matches natural cost boundaries. Fast tests catch regressions in the module system and daemon wiring. Full tests cover the rebuild/upgrade pipeline and networking. Heavy tests validate self-hosting and parallel builds — useful for release validation but too slow for every commit.

### 2. tier-vm stays as alias for tier-vm-fast

Current users of `nix build .#checks.x86_64-linux.tier-vm` get the same behavior plus 4 more quick tests. No surprise slowdowns.

### 3. Flat check namespace preserved

All 17 tests remain individually addressable: `nix build .#checks.x86_64-linux.network-test`. The tiers are aggregation targets only.

### 4. network tests use QEMU-only mode

The network-install-test and channel-update-test launch their own HTTP server process. QEMU SLiRP handles host↔guest routing entirely in-process — no real network needed. These work inside the Nix build sandbox.

## Risks / Trade-offs

- [Risk] Network tests bind to localhost ports inside Nix sandbox → some sandbox configs might block this.
  → Mitigation: QEMU SLiRP + loopback binding works in standard Nix sandbox. The existing bridge-test already does something similar.

- [Risk] tier-vm-heavy tests are so slow they'll never run in practice.
  → Mitigation: They're opt-in. `tier-vm-all` or individual `nix build .#checks...self-hosting-test` for release validation.

- [Risk] Adding 4 tests to tier-vm-fast increases CI time.
  → Mitigation: These are the cheapest VM tests (60-120s each). With Nix parallelism across independent derivations, wall-clock impact is small.
