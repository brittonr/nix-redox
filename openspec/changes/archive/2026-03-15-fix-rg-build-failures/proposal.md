## Why

The self-hosting test suite reports 57/62 PASS. The 5 failing tests (`rg-build`, `rg-version`, `rg-search`, `rg-store-path`, `rg-binary-size`) all cascade from a single root cause: `snix build --file /usr/src/ripgrep/build.nix` fails during the on-guest cargo build of ripgrep. Since the build failure predates the flock/poll-wait changes and happens consistently, it blocks validation of the full self-hosting pipeline (snix building a real 33-crate Rust project through a Nix derivation).

## What Changes

- Diagnose the ripgrep build failure by capturing the actual cargo/rustc error output from `build-ripgrep.sh`
- Fix the root cause (likely a crate compilation error, missing C dependency, or ring/TLS-related cross-compile issue specific to on-guest builds)
- Get all 5 rg-build tests to PASS, bringing the suite from 57/62 to 62/62
- Update `build-ripgrep.sh` and/or `build-ripgrep.nix` if builder changes are needed

## Capabilities

### New Capabilities

- `rg-build-fix`: Diagnosis and fix for ripgrep self-hosted build failures, covering cargo build error capture, crate-specific patches, and builder script hardening

### Modified Capabilities

None — existing specs for `nix-derivation-builds` and `parallel-cargo-builds` are unaffected. The fix is specific to the ripgrep source bundle and its build environment.

## Impact

- `nix/pkgs/infrastructure/build-ripgrep.sh` — builder script (error capture, env fixes)
- `nix/pkgs/infrastructure/build-ripgrep.nix` — derivation definition (possible env additions)
- `nix/pkgs/infrastructure/ripgrep-source-bundle.nix` — source bundle (possible vendored crate patches)
- `nix/redox-system/profiles/self-hosting-test.nix` — test harness (improved error reporting for rg-build tests)
- Self-hosting test result: 57/62 → 62/62 PASS
