## Context

`snix channel` (add/remove/list/update) and `snix system upgrade` are implemented in Rust (channel.rs, system.rs) but have no VM-level validation. The existing `network-install-test` profile proves HTTP binary cache fetch works over QEMU SLiRP — this test reuses the same infrastructure pattern (Python HTTP server on host, guest connects to 10.0.2.2) but exercises the channel → upgrade → generation pipeline.

The channel system stores state in `/nix/var/snix/channels/{name}/` with `url`, `manifest.json`, and `last-fetched` files. `snix system upgrade` calls `channel::update()` to fetch the manifest, compares it with the current system manifest, fetches missing packages from the channel's binary cache, then calls `system::switch()` to create a new generation.

## Goals / Non-Goals

**Goals:**
- Prove `snix channel add/list/update` works on real Redox
- Prove `snix system upgrade --yes` creates a new generation from a channel manifest
- Prove the upgrade detects "already up to date" on a second run
- Test with a manifest that adds a package (so `fetch_upgrade_packages` runs)

**Non-Goals:**
- Testing channel removal (trivial fs::remove_dir_all, not worth boot time)
- Testing `--dry-run` (code path is simple println, not worth a VM test)
- Testing HTTPS (no TLS stack on Redox yet)
- Testing channel-based rollback (rollback is already tested in rebuild-generations-test)

## Decisions

**Reuse network-install-test infrastructure.** Same pattern: build a test cache at Nix time, start Python HTTP server, boot QEMU with SLiRP, parse FUNC_TEST results from serial. The channel-update-test will be a separate flake app, not an extension of network-install-test, to keep test isolation clean.

**Serve a modified manifest as the channel.** The test cache serves the system's own `manifest.json` with one package added. This way the upgrade has real work to do (fetch the new package), and we can verify it landed.

**Build a "v2" manifest at Nix time.** The test profile generates two manifests: the "current" one baked into the disk image, and a "channel" one served via HTTP with an extra package and bumped version. The Nix build creates both as generated files.

**Test script writes to /nix/var/snix/channels/ directly.** `snix channel add` does the same thing (mkdir + write url file), so this is equivalent but lets us verify the low-level state.

## Risks / Trade-offs

**Test flakiness from network timing.** Mitigated by the proven DHCP wait loop from network-install-test (polls for 600 iterations). The channel update HTTP request is a single small JSON fetch.

**Manifest schema drift.** If the Manifest struct gains required fields, the static "channel manifest" in the test profile might fail to parse. Mitigated by generating the channel manifest from the same Nix build that creates the system manifest, so both schemas match.
