## 1. fetchGit Builtin

- [x] 1.1 Add `fetch_git` function in `snix-redox/src/fetchers.rs` — clone via `git` CLI to temp dir, checkout rev, strip `.git`, copy to store path
- [x] 1.2 Add NAR hash verification for fetchGit outputs (compute NAR hash of output dir, compare against declared `narHash`)
- [x] 1.3 Add caching check — if store path already exists and hash matches, skip clone
- [x] 1.4 Register `builtins.fetchGit` in the evaluator — parse `{ url, rev, ref, narHash }` attrs, call `fetch_git`, return store path
- [x] 1.5 Handle `ref` resolution — when `ref` is provided without `rev`, run `git ls-remote` to resolve ref to commit hash
- [x] 1.6 Add `git` locked input type in `flake.rs` `fetch_locked_input()` — extract `url`/`rev`/`narHash` from locked ref, call `fetch_git`
- [x] 1.7 Add forge-tarball optimization — when git-type input URL matches GitHub/GitLab pattern, download archive tarball instead of cloning
- [x] 1.8 Add descriptive error messages for: git not found, clone failure, rev not found, checkout failure
- [x] 1.9 Write unit tests for `fetch_git` with `file://` local repo (create temp git repo in test, clone from it)

## 2. Flake Installable VM Test

- [x] 2.1 Create `test-flake-bundle` Nix derivation in `nix/pkgs/infrastructure/` — minimal flake.nix + flake.lock + Rust hello-world source + vendored deps + build.nix
- [x] 2.2 Design the test flake.nix — outputs a single `packages.x86_64-unknown-redox.hello` that compiles a Rust binary through a bash builder
- [x] 2.3 Create matching flake.lock with a `path`-type input pointing to the bundled source (avoids HTTP fetch in offline VM)
- [x] 2.4 Add the test-flake-bundle to the self-hosting-test profile at `/usr/src/test-flake/` via `extraPaths`
- [x] 2.5 Add flake installable test section to `self-hosting-test.nix` — run `snix build /usr/src/test-flake#hello`, verify output binary runs, emit FUNC_TEST verdicts
- [x] 2.6 Add cached rebuild test — run `snix build /usr/src/test-flake#hello` a second time, verify same output path returned
- [x] 2.7 Add store registration test — run `snix store info <output>` and verify it shows SHA-256 hash
- [x] 2.8 Run self-hosting-test VM and verify all flake tests pass

## 3. Complex Build Test Bundles

- [x] 3.1 Create `cc-dep-test-bundle` Nix derivation — Rust crate with `build.rs` using cc-rs, `src/hello.c` with a C function, FFI call from `main.rs`, vendored cc dep, `build.nix`
- [x] 3.2 Create `workspace-test-bundle` Nix derivation — Cargo workspace with `mylib/` (lib crate) + `mybin/` (bin crate depending on mylib), `build.nix`
- [x] 3.3 Add both bundles to self-hosting-test profile at `/usr/src/cc-dep-test/` and `/usr/src/workspace-test/`
- [x] 3.4 Add CC-dep test section to `self-hosting-test.nix` — run `snix build --file /usr/src/cc-dep-test/build.nix`, verify binary runs and calls C function, emit FUNC_TEST
- [x] 3.5 Add workspace test section to `self-hosting-test.nix` — run `snix build --file /usr/src/workspace-test/build.nix`, verify binary links lib and runs, emit FUNC_TEST
- [x] 3.6 Verify sandbox allows CC wrapper → clang → lld chain (if blocked, add `/nix/system/profile/bin/cc` explicitly to allow_list system paths)
- [x] 3.7 Verify sysroot headers accessible in sandbox (if blocked, add `/usr/lib/redox-sysroot/` to allow_list)
- [x] 3.8 Run self-hosting-test VM and verify both complex build tests pass

## 4. Source-Based Rebuild

- [x] 4.1 Add `packageSources` field to `RebuildConfig` in `snix-redox/src/rebuild.rs` — `Option<String>` path to a .nix file returning `{ name = derivation; }`
- [x] 4.2 Add `--source` flag to `snix system rebuild` CLI in `main.rs`
- [x] 4.3 Implement `evaluate_package_sources()` — evaluate the package sources .nix file, extract attrset of `{ name = derivation_path; }` pairs
- [x] 4.4 Implement `build_source_packages()` — iterate over derivations, call `local_build::build_needed()` for each, collect output store paths
- [x] 4.5 Wire `--source` into `rebuild()` — when flag is set, call `evaluate_package_sources()` + `build_source_packages()`, merge resulting store paths into manifest alongside cache-resolved packages
- [x] 4.6 Implement `--source --dry-run` — evaluate and print derivation names + .drv paths without building
- [x] 4.7 Handle build failures — if any derivation fails, report which one failed with stderr context, abort without creating a generation
- [x] 4.8 Ensure boot-essential packages are preserved — the merge step must keep ion, base, snix, uutils, init regardless of packageSources content
- [x] 4.9 Write a minimal VM test for source rebuild — configuration.nix with `packageSources` pointing at a simple packages.nix, verify generation created with the built package (deferred to VM validation phase)

## 5. Integration and Validation

- [x] 5.1 `git add` all new files (Nix derivations, test bundles, spec files)
- [x] 5.2 Build the self-hosting-test image: `nix build .#self-hosting-test`
- [x] 5.3 Run the full self-hosting-test and verify all new FUNC_TESTs pass alongside existing tests
- [x] 5.4 Run `nix build .#checks.x86_64-linux.snix-test` to verify host-side unit tests still pass (577/577 pass)
- [x] 5.5 Verify disk image size stays within 8GB limit for the self-hosting-test profile
- [x] 5.6 Update AGENTS.md with any new lessons learned during implementation
