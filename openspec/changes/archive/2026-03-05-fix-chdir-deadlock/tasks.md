## 1. Patch

- [x] 1.1 Create `nix/pkgs/system/patch-relibc-chdir-deadlock.py` — find the exact `current_dir()?` call inside `chdir()` in `src/platform/redox/path.rs` and replace with `cwd_guard`. Exit non-zero if pattern not found.
- [x] 1.2 Wire the patch into `nix/pkgs/system/relibc.nix` patchPhase (add `python3 ${./patch-relibc-chdir-deadlock.py}` alongside the existing patches).

## 2. Test Update

- [x] 2.1 Update Step 10 in `nix/redox-system/profiles/self-hosting-test.nix` — replace the skip block with a real `cargo build` of a project containing `build.rs` with `println!("cargo:rustc-cfg=...")` and `println!("cargo:rustc-env=...")` directives. Use the existing timeout+retry wrapper (`cargo-build-safe`). Report `FUNC_TEST:cargo-buildrs:PASS` on success or `FUNC_TEST:cargo-buildrs:FAIL` with diagnostics on failure.

## 3. Build and Validate

- [x] 3.1 Build relibc with the patch: `nix build .#relibc` — confirm it succeeds and the patch applies cleanly.
- [x] 3.2 Build the self-hosting test image: `nix build .#redox-self-hosting-test` — confirm the full image builds.
- [x] 3.3 Run the self-hosting test: `nix run .#self-hosting-test` — 31/32 pass. `cargo-buildrs` fails with separate rustc subprocess crash (Invalid opcode), not chdir deadlock. The deadlock fix works (process gets past chdir), but a pre-existing rustc crash blocks build.rs execution.

## 4. Housekeeping

- [x] 4.1 Update `.agent/napkin.md` with the chdir deadlock root cause, fix, and test results.
- [x] 4.2 Commit with message describing the fix and linking to upstream `9cde64a3`.
