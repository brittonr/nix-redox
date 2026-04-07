## Why

snix can compile itself and build ripgrep through `snix build --file` on a running Redox guest, and the code for fetchGit, flake installables, C-dep builds, workspace builds, and source-based rebuilds was just landed (d5ee1559). The DSO-linked binary abort issue is fixed, and the self-hosting test suite runs end-to-end.

There's a concrete sequence of work needed to go from "cargo works on Redox" to "Nix manages a Redox system end-to-end": add remote binary cache support, wire up the store scheme, and close the rebuild loop so `snix system rebuild` can pull packages, build missing ones from source, activate the result, and roll back if needed.

## Phase ordering

This roadmap is **phase-two work**, gated on the stabilization baseline from `stabilize-self-hosting-baseline`. All tasks below are blocked until:

1. A full `self-hosting-test` run completes under the current scheme-only sandbox model
2. Remaining failures are classified and reflected in `fix-snix-build-gaps`
3. Flake installables honor the same sandbox-control path as other local builds
4. GitLab forge tarball URLs are verified by unit tests

Do not start remote cache, `stored`, generation management, or rebuild loop work until those exit criteria are met. See `stabilize-self-hosting-baseline` for the stabilization plan.

## What Changes

- **VM-validate the 4-gaps commit**: Run the self-hosting test suite with the new fetchGit, flake installable, C-dep, workspace, and source-rebuild code paths. Fix whatever breaks on the real guest (sandbox allow-list gaps, missing env vars, Ion/bash script issues). This is pure validation and bug-fixing — the Rust code exists.
- **Remote binary cache client**: Add HTTP transport to snix so `snix install`, `snix system rebuild`, and `snix build` can fetch NARs and narinfo from a remote cache served by the host (or any HTTP server). The local cache stays as fallback.
- **Store scheme daemon (`stored`)**: Implement the `store:` Redox scheme for lazy NAR extraction. Processes opening `store:hash-name/path` get a file descriptor backed by `/nix/store/hash-name/path`, with on-demand extraction from compressed NARs when the store path doesn't yet exist on disk.
- **Full guest rebuild flow**: Wire `snix system rebuild` end-to-end — evaluate `configuration.nix`, resolve packages from remote+local cache, build missing packages from source, generate init scripts/etc files, activate (update symlinks, restart changed services), create a generation, and recommend reboot when boot components change.
- **Generation management and rollback**: `snix system generations` to list, `snix system switch-generation N` to activate an older generation, `snix system delete-generations` to GC unused ones. Needed for safe iteration on a live system.

## Capabilities

### New Capabilities
- `self-hosting-vm-validation`: VM test coverage proving the 4-gaps code (fetchGit, flake installable, C-dep, workspace, source rebuild) works on a real Redox guest. Distinct from host-side unit tests.

### Modified Capabilities
- `remote-binary-cache`: Spec exists but is unimplemented. HTTP cache client for snix.
- `store-scheme`: Spec exists but is unimplemented. `stored` daemon with lazy extraction.
- `guest-rebuild`: Spec exists but the local+source+remote integration isn't wired. Full rebuild flow.
- `source-based-rebuild`: Code written, spec exists, needs VM validation and integration with remote cache fallback.
- `complex-on-guest-builds`: Code written, spec exists, needs VM validation.
- `flake-installable-vm-test`: Code written, spec exists, needs VM validation.
- `generation-gc`: Spec exists, unimplemented.
- `generation-management`: Spec exists, unimplemented.
- `e2e-rebuild-validation`: Spec exists, partially implemented (initial state works, rebuild cycle untested on guest).
- `rebuild-auto-routing`: Spec exists, needs integration with remote cache path.

## Impact

- **snix-redox** (`snix-redox/src/`): New code in `cache_source.rs` (HTTP transport), `stored/` (scheme daemon), `rebuild.rs` (full flow), `system.rs` (generation commands). Modifications to `install.rs`, `flake.rs`, `local_build.rs` for remote cache integration.
- **Nix profiles** (`nix/redox-system/profiles/`): `self-hosting-test.nix` gains new test phases for the validated code paths. May need a `rebuild-test.nix` profile for the end-to-end rebuild cycle.
- **Nix packages** (`nix/pkgs/`): `stored` becomes a new system package. Remote cache may need `minreq` or similar HTTP client crate vendored.
- **Init scripts** (`nix/redox-system/`): `stored` service definition in init, login_schemes update for `store:` scheme.
- **Disk image** (`nix/pkgs/infrastructure/`): Test bundles for flake/cc-dep/workspace already on image; may need a rebuild-test configuration.nix bundle.
- **Depends on**: `fix-relibc-panic-abort` must land first — everything here requires working DSO-linked binaries on the guest.
