## 1. Diagnose Build Failure

- [ ] 1.1 Build a self-hosting-test disk image and boot it in QEMU. Run the ripgrep build manually: `/nix/system/profile/bin/bash /usr/src/ripgrep/build-ripgrep.sh` with `out=/tmp/rg-test-out` and `TMPDIR=/tmp/rg-test-tmp`. Capture the full cargo output.
- [ ] 1.2 Read the cargo error output. Identify which crate fails and the exact compiler/linker error message. Record the failing crate name, error type (C compilation, linking, missing symbol, missing header, etc.), and relevant lines.
- [ ] 1.3 If the error is in a C-dependent crate (ring, libc, etc.), check whether `CC` is set and whether the cc wrapper receives correct flags (`-no-canonical-prefixes`, `-resource-dir`). Run the failing cc invocation manually to isolate the issue.
- [ ] 1.4 If cargo itself fails (not a crate compilation), check: is `CARGO_HOME` writable, does `.cargo/config.toml` exist in the source dir, are vendored crates intact, does `cargo metadata` work.

## 2. Fix Root Cause

- [ ] 2.1 Apply the fix based on diagnosis. Likely locations: `nix/pkgs/infrastructure/build-ripgrep.sh` (env vars, flags), `nix/pkgs/infrastructure/build-ripgrep.nix` (derivation env), or a vendored crate patch in `nix/pkgs/infrastructure/ripgrep-source-bundle.nix`.
- [ ] 2.2 If a vendored crate needs patching: write the patch, regenerate `.cargo-checksum.json` for that crate (recompute SHA-256 of patched files), and update the source bundle derivation.
- [ ] 2.3 If the fix requires a new env var (CC, CFLAGS, etc.), add it to `build-ripgrep.sh` with a comment explaining why.

## 3. Harden Error Reporting

- [ ] 3.1 In `build-ripgrep.sh`, change the final failure dump from `tail -c 4096` to `cat` so the full build log reaches stderr. Add a line count and byte count header so truncation by the serial buffer is detectable.
- [ ] 3.2 In `build-ripgrep.sh`, add `echo` statements at each retry boundary showing attempt number, elapsed time, and exit code.
- [ ] 3.3 In the self-hosting-test harness (`self-hosting-test.nix`), verify that the `cat /tmp/rg-build-err` block emits enough context through serial. If the build log is huge, emit the first 2KB and last 2KB with a marker between them.

## 4. Validate

- [ ] 4.1 Rebuild the disk image with the fix applied. Boot and run `snix build --file /usr/src/ripgrep/build.nix` on the guest. Confirm exit code 0 and a valid output path.
- [ ] 4.2 Run the built `$OUTPUT/bin/rg --version` and confirm it prints a version string containing `ripgrep`.
- [ ] 4.3 Run `$OUTPUT/bin/rg "hello" /tmp/test.txt` against a known file and confirm correct search results.
- [ ] 4.4 Run the full self-hosting-test profile through `nix build .#test-self-hosting`. Confirm all 5 rg tests flip to PASS: `rg-build`, `rg-version`, `rg-search`, `rg-store-path`, `rg-binary-size`.
- [ ] 4.5 Confirm total test count reaches 62/62 PASS (no regressions in the other 57 tests).

## 5. Cleanup

- [ ] 5.1 Update AGENTS.md if the fix introduces new cross-compilation knowledge (new env vars, crate-specific workarounds, ring build quirks).
- [ ] 5.2 Add a comment in `build-ripgrep.sh` documenting the root cause and fix for future reference.
