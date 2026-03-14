## 1. Update source bundle cargo configs

- [x] 1.1 Update `snix-source-bundle.nix` `.cargo/config.toml` to include `jobs = 2`, `target = "x86_64-unknown-redox"`, and `linker = "/nix/system/profile/bin/cc"` (currently only has vendor source replacement)
- [x] 1.2 Update `ripgrep-source-bundle.nix` `.cargo/config.toml` to include `jobs = 2` (currently has `jobs = 1`; already has target and linker settings)

## 2. Add builder scripts to source bundles

- [x] 2.1 Write `build-snix.sh` — bash builder script for snix: sets PATH/LD_LIBRARY_PATH/CARGO_HOME/AR, copies source to writable $TMPDIR, runs `cargo build --offline` with background+polling+timeout (MAX_TIME=1800), copies `target/x86_64-unknown-redox/debug/snix` to `$out/bin/snix`
- [x] 2.2 Write `build-ripgrep.sh` — bash builder script for ripgrep: same env setup, copies source to writable $TMPDIR, runs `cargo build --offline --bin rg -j2` with polling+timeout (MAX_TIME=600) and 3 retry attempts, copies `target/x86_64-unknown-redox/debug/rg` to `$out/bin/rg`
- [x] 2.3 Add `build-snix.sh` to `snix-source-bundle.nix` output (`cp` into `$out/`)
- [x] 2.4 Add `build-ripgrep.sh` to `ripgrep-source-bundle.nix` output (`cp` into `$out/`)

## 3. Add build.nix files to source bundles

- [x] 3.1 Write `build-snix.nix` — Nix derivation expression: `derivation { name = "snix-self-compiled"; builder = "/nix/system/profile/bin/bash"; args = ["/usr/src/snix-redox/build-snix.sh"]; system = "x86_64-unknown-redox"; }`
- [x] 3.2 Write `build-ripgrep.nix` — Nix derivation expression: `derivation { name = "ripgrep-on-redox"; builder = "/nix/system/profile/bin/bash"; args = ["/usr/src/ripgrep/build-ripgrep.sh"]; system = "x86_64-unknown-redox"; }`
- [x] 3.3 Add `build.nix` to `snix-source-bundle.nix` output
- [x] 3.4 Add `build.nix` to `ripgrep-source-bundle.nix` output

## 4. Replace snix-compile test section

- [x] 4.1 Replace the snix-compile section in `self-hosting-test.nix` (currently ~100 lines: copy source, write cargo config, cargo build with polling, check result) with a ~30 line block: check `/usr/src/snix-redox/build.nix` exists, run `snix build --file /usr/src/snix-redox/build.nix`, verify output path starts with `/nix/store/`, run `$OUTPUT/bin/snix --version`, emit FUNC_TEST verdicts
- [x] 4.2 Keep existing FUNC_TEST names: `snix-src-present`, `snix-vendor-present`, `snix-compile`, `snix-binary-exists`, `snix-binary-runs`, `snix-eval-selfbuilt`
- [x] 4.3 Remove the inline `.cargo/config.toml` generation from the test script (now lives in source bundle)

## 5. Replace rg-build test section

- [x] 5.1 Replace the rg-build section in `self-hosting-test.nix` (currently ~150 lines: copy source, write cargo config, create inline flake.nix+flake.lock+builder, snix build .#ripgrep) with a ~30 line block: check `/usr/src/ripgrep/build.nix` exists, run `snix build --file /usr/src/ripgrep/build.nix`, verify output, emit FUNC_TEST verdicts
- [x] 5.2 Keep existing FUNC_TEST names: `rg-src-present`, `rg-vendor-present`, `rg-build`, `rg-version`, `rg-search`, `rg-store-path`, `rg-binary-size`
- [x] 5.3 Remove the inline flake.nix, flake.lock, and build-ripgrep.sh generation from the test script

## 6. Verify build

- [x] 6.1 `git add` all new files (source bundle .nix changes, builder scripts, build.nix files)
- [x] 6.2 Run `nix build .#redox-self-hosting-test` to verify the image builds with the updated source bundles
- [x] 6.3 Verify source bundles contain build.nix and builder scripts by inspecting the Nix store output
