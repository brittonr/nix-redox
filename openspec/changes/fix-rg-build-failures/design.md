## Context

The self-hosting test suite runs 62 tests. 57 pass. The 5 failures (`rg-build`, `rg-version`, `rg-search`, `rg-store-path`, `rg-binary-size`) all cascade from a single root: `snix build --file /usr/src/ripgrep/build.nix` fails during `cargo build --offline --bin rg -j2` inside the guest. The 4 downstream tests (`rg-version`, `rg-search`, `rg-store-path`, `rg-binary-size`) check the output binary—they emit `FAIL:no binary` because the build never produces one.

The builder script (`build-ripgrep.sh`) does:
1. Set PATH, LD_LIBRARY_PATH, CARGO_HOME, AR
2. Copy `/usr/src/ripgrep` to a writable tmpdir
3. Run `cargo build --offline --bin rg -j2` with timeout/retry (3 attempts, 600s each)
4. Copy the resulting binary to `$out/bin/rg`

The derivation (`build-ripgrep.nix`) is minimal—just `bash` as the builder, no env vars passed through. The source bundle (`ripgrep-source-bundle.nix`) vendors all crate dependencies and provides `.cargo/config.toml` with offline source replacement and `x86_64-unknown-redox` as the build target.

The actual cargo error is not visible in test output. The builder redirects cargo stdout+stderr to `$TMPDIR/rg-build-log` and only dumps the last 4KB to stderr on the final (3rd) failed attempt. The test harness captures snix's stderr to `/tmp/rg-build-err` and prints it on failure, but the serial log may truncate long output.

ripgrep has 33 crates. Several depend on C code (ring for TLS, pcre2 optional, libc shims). The `cc-rs` crate drives C compilation and reads `AR`, `CC`, and linker env vars. The CC wrapper on Redox requires `-no-canonical-prefixes` and explicit `-resource-dir` to function (see AGENTS.md). The builder already sets `AR=/nix/system/profile/bin/llvm-ar` but does not explicitly set `CC`.

## Goals / Non-Goals

**Goals:**
- Capture the actual cargo build error from the guest so the root cause is visible
- Fix whatever is breaking the ripgrep cargo build inside the snix derivation
- Get all 5 rg tests to PASS, bringing the suite from 57/62 to 62/62
- Harden error reporting so future build failures are diagnosable without guesswork

**Non-Goals:**
- Changing the ripgrep version or switching to a different crate for validation
- Optimizing build speed (JOBS=2 is already set, that's fine)
- Adding new test cases beyond the existing 5
- Fixing unrelated self-hosting issues

## Decisions

### 1. Diagnose first, fix second

**Choice**: Run the build with enhanced error capture before attempting any fix. Add diagnostic output to `build-ripgrep.sh` that dumps the full build log on failure (not just last 4KB). Improve the test harness to surface more of the builder's stderr through serial.

**Rationale**: The failure could be any of: missing env var, C compilation error in a dependency crate, cargo config issue, linker failure, ring crate assembly problem, or a snix sandbox interaction. Guessing wastes time. The builder already captures the log—we just need to see it.

### 2. Fix in the builder script and/or derivation, not the source bundle

**Choice**: Fixes go in `build-ripgrep.sh` (env setup, error handling) and/or `build-ripgrep.nix` (derivation env vars). The source bundle (`ripgrep-source-bundle.nix`) and vendored crates stay unchanged unless a vendored crate needs a Redox-specific patch.

**Alternatives considered**:
- **Patch vendored crates**: Only if the error traces to a crate source bug. Requires regenerating `.cargo-checksum.json` which is fragile.
- **Change the derivation to pass env vars**: Possible for PATH, LD_LIBRARY_PATH, CC, but the builder script already sets these. Only needed if snix strips them.

**Rationale**: The builder script is the single control point for the build environment. It already handles PATH, LD_LIBRARY_PATH, CARGO_HOME, and AR. Adding CC or other missing variables there keeps the fix localized and consistent with the existing pattern.

### 3. Dump full build log through serial on failure

**Choice**: On build failure, the test harness prints the full `/tmp/rg-build-err` and the builder dumps its complete build log to stderr (not truncated to 4KB). Serial output may still truncate, but more context is better than less.

**Rationale**: The current 4KB tail misses early errors (the first failing crate is often early in the dependency graph). The test harness already `cat`s `/tmp/rg-build-err`, but the builder feeds it only a truncated slice.

## Risks / Trade-offs

- **[Risk] Serial log overflow**: Dumping the full cargo build log (could be 100KB+) through serial may overwhelm the capture buffer. → Mitigate by dumping to a file on the guest and printing a bounded summary (first error + last N lines). The diagnostic run can use a larger buffer.
- **[Risk] Multiple root causes**: The build might fail for one reason on attempt 1 and a different reason on attempts 2-3 (e.g., stale lockfiles from a killed cargo). → The retry logic already cleans `.package-cache`; we add cleanup of any partial build artifacts between attempts.
- **[Risk] Vendored crate patch needed**: If ring or another crate has Redox-incompatible build logic, patching the vendor dir requires checksum regeneration. → Follow the established pattern: patch the source, recompute SHA-256, update `.cargo-checksum.json`. Document in AGENTS.md.
- **[Risk] CC not set explicitly**: The cc-rs crate auto-detects CC but may pick the wrong binary or miss Redox-specific flags. → If diagnosis shows a C compilation error, explicitly set `CC` in the builder to the sysroot cc wrapper.
