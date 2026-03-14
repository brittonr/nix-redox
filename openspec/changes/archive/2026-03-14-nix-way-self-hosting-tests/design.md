## Context

The self-hosting test profile (`self-hosting-test.nix`) validates that Rust compilation works on a running Redox OS guest. It currently has three tiers of compilation tests:

1. **Direct cargo builds** (Phase 3): Inline hello-world, multifile, proc-macro, etc. — run `cargo build` directly in Ion/bash blocks. These prove cargo+rustc work.
2. **Simple snix builds** (Phase 4): `snix build --expr "..."` with trivial derivations (echo to $out). Prove snix eval + build pipeline works.
3. **snix-build-cargo**: A proper derivation that runs cargo inside a builder script via `snix build --file`. Proves the full pipeline: nix eval → derivation → cargo → binary in `/nix/store/`.

The snix-compile test (168 crates) and rg-build test (55 crates through a flake) are the heavyweight compilation tests. They should follow the snix-build-cargo pattern (tier 3) rather than direct cargo (tier 1).

Currently:
- **snix-compile** copies `/usr/src/snix-redox` to `/tmp/snix-build`, writes a `.cargo/config.toml` inline, runs `cargo build --offline` with a background+polling+timeout loop. Output goes to `/tmp/snix-build/target/`, not the Nix store.
- **rg-build** copies `/usr/src/ripgrep` to `/tmp/rg-build`, writes `.cargo/config.toml` inline, then creates an entire flake.nix + flake.lock + build-ripgrep.sh in `/tmp/rg-flake/` using triple-nested heredocs in Ion shell. It calls `snix build ".#ripgrep"`, but the flake definition is fragile and hard to modify.

The snix-build-cargo test already proves the pattern: ship a `.nix` file and builder script → `snix build --file` → cargo → `/nix/store/` output. We just need to apply it to the bigger builds.

## Goals / Non-Goals

**Goals:**
- snix-compile and rg-build tests go through `snix build --file <path>` with pre-baked builder scripts
- Builder scripts and `.nix` files are part of the source bundles (built on the host, shipped on the image)
- Test script becomes: check source → `snix build` → verify output → PASS/FAIL
- Output binaries land in `/nix/store/` (content-addressed, registered in PathInfoDb)
- Existing test names (`FUNC_TEST:snix-compile`, `FUNC_TEST:rg-build`, etc.) preserved

**Non-Goals:**
- Not changing the Phase 3 direct-cargo tests (hello, multifile, proc-macro, etc.) — those test cargo itself, not the Nix pipeline
- Not changing the simple snix-build tests (Phase 4 tier) — those test snix eval basics
- Not implementing `snix build .#<flake-attr>` for snix-compile (--file is simpler and already works)
- Not changing the parallel-jobs2 smoke test
- Not removing the polling+timeout pattern from builder scripts — cargo on Redox still needs it

## Decisions

**Ship build.nix + builder.sh in source bundles, not inline in the test script.**
The source bundles (`snix-source-bundle.nix`, `ripgrep-source-bundle.nix`) already create directories with source + vendor + `.cargo/config.toml`. Adding `build.nix` and a builder script is natural. This eliminates the triple-nested heredoc quoting for rg-build and the inline cargo config generation for snix-compile.

Alternative: generate the .nix files in the test script (current rg-build approach). Rejected because the quoting is fragile and hard to debug.

**Use `snix build --file` not `snix build .#attr`.**
The `--file` interface takes a path to a `.nix` file and evaluates it directly. No flake.nix or flake.lock needed. The rg-build test currently creates both — that complexity adds no test value. The `--file` interface is simpler, already validated by snix-build-cargo and snix-build-file tests.

Alternative: keep `snix build .#ripgrep` for rg-build. Rejected because it requires creating flake.nix + flake.lock on the guest, adding quoting complexity for no additional coverage.

**Builder scripts keep the polling+timeout+retry pattern.**
Cargo on Redox can still hang intermittently. The builder scripts need the same `background + kill -0 + /scheme/sys/uname poll + timeout` pattern that snix-build-cargo already uses. This moves from the test script into the builder script (where it belongs — the builder knows its own timeout needs).

**cargo config stays in the source bundle's .cargo/config.toml.**
Both source bundles already ship `.cargo/config.toml` with vendor source replacement and target settings. The test script currently overwrites this with an inline version (adding JOBS=2). Instead, the source bundles should include the complete config (with JOBS=2) and the builder script should just use it.

**Test script pattern: single bash block per test.**
Keep the `FUNC_TEST:` emit pattern inside bash blocks. The snix build call replaces ~100 lines of cargo setup+build+polling per test with ~20 lines of snix-build-call+verify.

## Risks / Trade-offs

**[Disk space] snix build puts output in /nix/store/ instead of /tmp/**
→ The self-hosting test image is already 8GB. Snix binary is ~15MB, rg is ~5MB. /nix/store/ on Redox is on the same filesystem. Non-issue.

**[Build time] snix build adds overhead (eval + pathinfo registration) on top of cargo**
→ Overhead is <1 second for eval + registration. The cargo build dominates (500-900s). Negligible.

**[Debugging] Builder script output goes to snix's stderr, not directly to serial**
→ snix build --file already prints builder output to stderr (Stdio::inherit). Serial captures it. Same debugging experience as today.

**[Failure modes] snix build failure wraps the cargo failure**
→ The FUNC_TEST verdict already checks the exit code and output path. The build log is still available via `/tmp/` files (builder scripts can write there). Error messages from snix are clear ("builder for X failed with exit code Y").
