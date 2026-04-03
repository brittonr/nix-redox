## Context

snix on Redox has a working local builder with per-path sandbox, flake evaluation, and binary cache integration. The self-hosting test suite validates: single-file rustc, cargo with vendored deps, proc-macros, snix self-compile (193 crates), and ripgrep build (33 crates) — all through `snix build --file`.

Four gaps remain between current state and full Nix self-hosting:

1. `snix build .#package` (flake installable) has 1272 lines of implementation in `flake.rs` but zero VM test coverage. It could be silently broken.
2. `snix system rebuild` resolves package names against `/nix/cache/packages.json` — a pre-built binary cache index. There's no way to compile a package from a Nix expression during rebuild.
3. On-guest builds with C library dependencies (cc-rs build.rs → clang) or Cargo workspace crates have never been tested. The sandbox, CC wrapper, and sysroot may need adjustments.
4. `fetchGit` returns a hard error. Any flake with `git`-type locked inputs fails at input resolution time.

The self-hosting profile already includes: rustc, cargo, clang/lld/llvm-ar, relibc sysroot, CC wrapper, git, bash, make, cmake. The tools are on the image — they just haven't been exercised through these paths.

## Goals / Non-Goals

**Goals:**
- Validate `snix build .#package` in a VM test with an offline test flake
- Add `snix system rebuild --source` that evaluates and builds packages from Nix expressions
- Prove C-dep and workspace crate builds work on-guest through snix (at least one of each)
- Implement `builtins.fetchGit` and git-type locked input resolution
- All new capabilities covered by VM tests in the existing check tier system

**Non-Goals:**
- Flake lock file writing (`nix flake lock` / `nix flake update`) — read-only lock consumption is sufficient
- Flake registries or `--override-input`
- `fetchGit` with SSH authentication (HTTPS-only is fine for now)
- Submodule support in fetchGit
- Building the entire Redox system image from source on-guest (that's a future milestone)
- IFD (import-from-derivation) support in the evaluator
- Remote builders or distributed builds

## Decisions

### 1. Offline test flake for VM validation

**Decision**: Ship a minimal test flake (flake.nix + flake.lock + vendored input source) on the disk image as `/usr/src/test-flake/`. The flake defines one package that compiles a hello-world Rust crate.

**Rationale**: The self-hosting VM tests run without network access (no QEMU SLiRP). Shipping the flake input as a pre-fetched tarball on the image lets us test the full installable flow — parse, lock resolution, eval, build — without HTTP. This matches how snix-source-bundle and ripgrep-source-bundle already work.

**Alternative considered**: Use QEMU networking to fetch from a host-served cache. Rejected because it adds network test infrastructure complexity and the flake code path we need to test is parse → eval → build, not HTTP fetch.

### 2. Source rebuild via package-set Nix file

**Decision**: `snix system rebuild --source` evaluates a `packages.nix` file (referenced from `configuration.nix`) that returns an attrset of `{ name = derivation; }` pairs. Each derivation is built through the existing `local_build::build_needed()` pipeline. The resulting store paths replace the binary-cache-resolved paths in the manifest.

**Rationale**: This keeps the rebuild module's architecture intact — it still produces a manifest with store paths, just sourced from local builds instead of cache lookups. The package-set file is a plain Nix attrset, not a full nixpkgs clone — users write derivations for the packages they want to build from source.

**Alternative considered**: Full nixpkgs-style evaluation with `callPackage` patterns. Rejected as premature — the evaluator handles attrsets and derivations fine, but a full nixpkgs import would need IFD, mass fetchurl, and many more builtins. The attrset approach is sufficient for the "build my own packages from source" use case.

### 3. fetchGit via git CLI

**Decision**: Implement `builtins.fetchGit` by shelling out to the `git` binary already on the self-hosting image. Clone to a temp dir, checkout the specified rev, copy the working tree to a computed store path.

**Rationale**: The self-hosting profile already includes `redox-git`. A native git library (libgit2) would need cross-compilation and C-dep handling — circular with the problem we're solving. Shelling out to `git` is what Nix itself does for `fetchGit`.

**Alternative considered**: Resolve git inputs as tarball downloads from known forges (GitHub/GitLab archive URLs). This works for github/gitlab types (already implemented) but not for arbitrary git URLs or local git repos. Real `fetchGit` is needed for the general case.

### 4. C-dep test target: a crate using cc-rs

**Decision**: Use a minimal synthetic crate with a `build.rs` that invokes `cc::Build::new().file("src/hello.c").compile("hello")`, linking the result into a Rust binary. This exercises the cc-rs → CC wrapper → clang → lld pipeline without requiring a real C library cross-build.

**Rationale**: Testing with a real C library (bzip2, zlib) would require shipping the library source + autotools/cmake on the test image, making the test slow and fragile. A synthetic crate isolates the cc-rs path. The CC wrapper, clang, and sysroot are already on the image from the self-hosting profile.

**Alternative considered**: Build an actual C library (bzip2). Rejected for test isolation — if bzip2's configure script fails, we can't tell if snix or bzip2 is broken.

### 5. Workspace test target: synthetic two-crate workspace

**Decision**: Ship a two-crate Cargo workspace (a lib crate + a bin crate that depends on it) as a test bundle. Build through `snix build --file` with a build.nix.

**Rationale**: Workspace builds exercise cargo's multi-crate coordination, which uses different fingerprinting and dep-resolution paths than single-crate builds. A synthetic workspace is deterministic and fast. Real workspaces (extrautils, orbutils) have many deps and would be slow.

### 6. Test placement in VM tier system

**Decision**: Place the flake-installable test in the existing `self-hosting-test` profile (tier-vm-heavy). Add a separate `complex-build-test` profile for C-dep + workspace tests, also in tier-vm-heavy.

**Rationale**: These tests need the full self-hosting toolchain (8GB RAM, 4 CPUs, ~8GB disk) and take minutes to run. They belong in the heavy tier alongside the existing self-compile and ripgrep tests.

## Risks / Trade-offs

**[fetchGit clone is slow on Redox]** → The git binary on Redox uses HTTPS via curl/openssl. Clone speed depends on relibc's TLS performance. Mitigation: fetchGit tests use small repos or local `file://` paths. The offline test flake avoids fetchGit entirely.

**[Source rebuild increases rebuild time from seconds to minutes]** → Binary cache resolve is O(1) lookup; source build is O(minutes) per package. Mitigation: `--source` is opt-in. Default rebuild path remains binary-cache-based. Document that `--source` is for development/bootstrapping, not routine updates.

**[CC wrapper edge cases in sandbox]** → The per-path proxy sandbox must allow the CC wrapper to invoke clang, which in turn invokes lld. All three are in `/nix/system/profile/bin/` which is already on the read-only allow list. Risk is in response-file handling (`@file` args from cargo) and temp file creation. Mitigation: The sandbox already allows `$TMPDIR` read-write, and cc-rs writes temp files there.

**[Cargo workspace fingerprint instability]** → The two-phase kernel build showed that cargo fingerprints are fragile across Nix store boundaries. On-guest builds don't have this problem (single build, no phase split), but workspace dep-graph changes could trigger unexpected recompilation. Mitigation: Test with `CARGO_INCREMENTAL=0` to disable incremental compilation.

**[Disk image size growth]** → Adding test flake bundles and source-rebuild infrastructure increases the test image. Current self-hosting test uses 8GB. Mitigation: Keep test bundles minimal (synthetic crates, not full projects). Monitor image size in CI.
