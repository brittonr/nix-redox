## Why

Self-hosting work is split across two active changes with very different scopes:

- `fix-snix-build-gaps` is the short path to a credible self-hosting baseline.
- `nix-self-hosting-roadmap` is the larger expansion plan: remote cache, store scheme, generation management, and rebuild flows.

That split was manageable while the build pipeline was stable. It is not stable now. The latest builder change (`70b70d74`) disabled the per-path proxy sandbox and switched `snix` back to scheme-level sandboxing. That resets the validation baseline for flake builds, cargo builds, and full `self-hosting-test` runs. At the same time, host-side cache failures (`cache.snix.dev` narinfo protocol mismatch) can slow validation enough to blur the line between Redox-side bugs and infrastructure noise.

We need a focused self-hosting plan that answers one question first: what is the current, validated self-hosting baseline after the sandbox rollback? Until that is answered, adding remote cache, store scheme, rollback, or other roadmap work will mix new feature risk with stale validation data.

## What Changes

- Rebaseline the self-hosting test suite after the sandbox rollback and record the real pass/fail set.
- Fix the small but high-leverage `snix-redox` issues that block or distort that baseline:
  - flake installables ignoring `--no-sandbox`
  - GitLab forge tarball URL generation
  - stale proxy-only plumbing in the local builder path
  - sandbox docs/comments that no longer match reality
- Refresh `fix-snix-build-gaps` so its remaining tasks reflect the current scheme-only sandbox world instead of the removed proxy path.
- Make `nix-self-hosting-roadmap` explicitly phase-two work, gated on a fresh stabilization baseline.
- Keep hardware bring-up, network drivers, and bare-metal issues out of scope for this change.

## Capabilities

### New Capabilities
- `self-hosting-baseline`: A current, recorded self-hosting validation baseline after major `snix` build-path changes.
- `flake-build-option-parity`: Flake installables use the same build-option plumbing as `--expr` and `--file` builds.
- `forge-input-url-correctness`: Locked GitLab and GitHub flake inputs resolve to valid archive URLs.

### Modified Capabilities
- `nix-derivation-builds`: Validation is re-run and recorded after the scheme-only sandbox switch.
- `flake-installable-vm-test`: Flake builds are validated through the same sandbox-control path as other local builds.
- `source-based-rebuild`: Reverification happens only after the baseline and flake path are stable.

## Impact

- **Files**:
  - `snix-redox/src/local_build.rs`
  - `snix-redox/src/flake.rs`
  - `snix-redox/src/main.rs`
  - `snix-redox/src/sandbox.rs`
  - `nix/redox-system/profiles/self-hosting-test.nix`
  - `openspec/changes/fix-snix-build-gaps/*`
  - `openspec/changes/nix-self-hosting-roadmap/*`
- **Testing**:
  - `nix run .#self-hosting-test`
  - focused guest verification for flake, cargo/workspace, and source-rebuild paths
  - host-side unit tests for flake URL and option plumbing
- **Non-goals**:
  - hardware bring-up
  - NIC/ACPI/PCIe work
  - OpenSSH work
  - store scheme or remote cache implementation beyond what is needed to get a clean validation baseline
