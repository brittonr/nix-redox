## Why

The snix-compile test (self-compile of snix from source) runs `cargo build --offline` directly inside a bash block on the guest. The rg-build test creates an ad-hoc flake.nix inline and runs `snix build ".#ripgrep"`, but the builder script inside that derivation also calls `cargo build --offline` with its own timeout/retry/polling loop. Neither test builds through a proper Nix derivation defined on the host side. We already proved the pattern works: snix-build-cargo compiles a hello-world Rust crate through `snix build --file` with a builder script. The snix-compile and rg-build tests should follow the same pattern — define proper Nix derivations with builder scripts and invoke them through `snix build`.

This matters because:
- Direct `cargo build` bypasses the Nix store, so test output isn't content-addressed or registered.
- The rg-build test writes its flake.nix inline in Ion shell with triple-nested quoting (`'"'"'`). It's fragile and hard to modify.
- The snix-compile test doesn't go through snix at all — it proves cargo works, not that snix can build snix.
- The existing snix-build-cargo test already shows the right pattern: `.nix` file → `snix build --file` → builder script → cargo → binary in `/nix/store/`.

## What Changes

- Replace the snix-compile test's direct `cargo build` with a `snix build --file /usr/src/snix-redox/build.nix` invocation. The builder script (already proven in snix-build-cargo) handles cargo build + timeout + output.
- Replace the rg-build test's inline flake.nix with a pre-baked `.nix` file and builder script shipped in the ripgrep source bundle. `snix build --file /usr/src/ripgrep/build.nix` replaces the inline heredoc flake.
- Builder scripts for both are pre-installed as part of their source bundles (added in `snix-source-bundle.nix` and `ripgrep-source-bundle.nix`), not generated inline.
- The test script reduces to: check source present, call `snix build --file`, check output path, run binary, emit PASS/FAIL.
- Remove ~200 lines of inline cargo build + polling + timeout + cargo config from the test script.

## Capabilities

### New Capabilities
- `nix-derivation-builds`: Self-hosting compilation tests (snix, ripgrep) go through `snix build` with pre-baked Nix files and builder scripts, producing content-addressed outputs in `/nix/store/`.

### Modified Capabilities

## Impact

- `nix/redox-system/profiles/self-hosting-test.nix` — test script shrinks significantly (snix-compile and rg-build sections replaced with snix build calls)
- `nix/pkgs/infrastructure/snix-source-bundle.nix` — adds `build.nix` + `build-snix.sh` to the bundle
- `nix/pkgs/infrastructure/ripgrep-source-bundle.nix` — adds `build.nix` + `build-ripgrep.sh` to the bundle
- Test names (`FUNC_TEST:snix-compile`, `FUNC_TEST:rg-build`, etc.) stay the same for CI compatibility
- Disk image size may need adjustment (snix build artifacts go to `/nix/store/` instead of `/tmp/`)
