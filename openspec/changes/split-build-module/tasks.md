## 1. Baseline snapshot

- [x] 1.1 Record the store hash of `rootTree` for the `minimal` profile
- [x] 1.2 Record the store hash of `rootTree` for the `functional-test` profile
- [x] 1.3 Record the store hash of `rootTree` for the `graphical` profile
- [x] 1.4 Record the store hash of `rootTree` for the `self-hosting` profile

## 2. Rust tool: fix-elf-palign

- [x] 2.1 Create `nix/pkgs/host/fix-elf-palign/` with `Cargo.toml` and `src/main.rs` — takes a root dir arg, walks `nix/store/` and `lib/` subdirs, finds `.so`/`.so.6`/`rustc`/`rustdoc` files (skipping symlinks), patches 64-bit LE ELF program headers with `p_align=0` → `p_align=1`, prints count. No external crate dependencies (just `std::fs`, `std::io` byte manipulation).
- [x] 2.2 Create `nix/pkgs/host/fix-elf-palign.nix` — `rustPlatform.buildRustPackage` derivation for the host
- [x] 2.3 Add to `nix/pkgs/host/` exports so it's available as `hostPkgs.fix-elf-palign`
- [x] 2.4 Write a `#[test]` that creates a minimal ELF file with `p_align=0`, runs the fixer, and verifies `p_align=1`
- [x] 2.5 `cargo test` passes, `nix build` succeeds

## 3. Rust tool: hash-manifest

- [x] 3.1 Create `nix/pkgs/host/hash-manifest/` with `Cargo.toml` and `src/main.rs` — takes a root dir arg, reads `etc/redox-system/manifest.json`, walks tree computing BLAKE3 hashes (skipping manifest itself, `etc/redox-system/generations/`, `nix/store/`, symlinks), computes buildHash from sorted inventory JSON, writes final manifest, seeds `generations/1/`. Uses `blake3`, `serde_json`, `walkdir` crates.
- [x] 3.2 Create `nix/pkgs/host/hash-manifest.nix` — `rustPlatform.buildRustPackage` derivation for the host
- [x] 3.3 Add to `nix/pkgs/host/` exports
- [x] 3.4 Write `#[test]`s: creates a temp tree with files and a base manifest, runs hasher, verifies files key populated, buildHash present, generation 1 seeded, excluded paths absent
- [x] 3.5 `cargo test` passes, `nix build` succeeds

## 4. Extract config.nix

- [x] 4.1 Create `nix/redox-system/modules/build/config.nix` as a function `{ lib, inputs, pkgs, redoxLib }:` returning the computed config attrset (feature flags, package partitions, daemon lists, directory lists, user info — lines ~83–415 of current default.nix)
- [x] 4.2 Import `config.nix` from `default.nix` and replace the inline definitions with references to the returned attrset
- [x] 4.3 Verify `nix eval` still works for a minimal profile (no eval errors)

## 5. Extract assertions.nix

- [x] 5.1 Create `nix/redox-system/modules/build/assertions.nix` as a function taking config + inputs, returning `{ assertions, warnings, assertionCheck, warningCheck }`
- [x] 5.2 Wire into `default.nix` — `rootTree` still `assert assertionCheck; assert warningCheck;`
- [x] 5.3 Verify the graphics-without-orbital assertion still fires (`nix eval` with bad config)

## 6. Extract pcid.nix

- [x] 6.1 Create `nix/redox-system/modules/build/pcid.nix` as a function `{ lib, allDrivers }:` returning `{ pciRegistry, pcidDrivers, pcidToml }`
- [x] 6.2 Wire into `default.nix` — initfs and rootTree use `pcid.pcidToml`
- [x] 6.3 Verify pcid.toml content unchanged (`nix eval` the attrset, diff against known-good)

## 7. Extract generated-files.nix

- [x] 7.1 Create `nix/redox-system/modules/build/generated-files.nix` as a function taking config + inputs, returning the `allGeneratedFiles` attrset (all `/etc/` files, security, networking, logging, power, programs, snix config, cargo config, manifest source)
- [x] 7.2 Wire into `default.nix` — `root-tree.nix` consumes this attrset
- [x] 7.3 Verify `etc/profile` content unchanged for minimal and graphical profiles

## 8. Extract init-scripts.nix

- [x] 8.1 Create `nix/redox-system/modules/build/init-scripts.nix` as a function taking config + inputs, returning `{ initScriptFiles, allInitScripts, renderedServices, allInitScriptsWithServices, initToml, startupContent }`
- [x] 8.2 Wire into `default.nix` — feeds both `generated-files.nix` (for rootfs init scripts) and `initfs.nix` (for initfs init.d scripts)
- [x] 8.3 Verify initfs init.d script content unchanged for minimal and graphical profiles

## 9. Extract root-tree.nix

- [x] 9.1 Create `nix/redox-system/modules/build/root-tree.nix` as a function taking `{ hostPkgs, lib, config, generatedFiles, initScripts, binaryCache, assertionCheck, warningCheck, fix-elf-palign, hash-manifest }` and returning the `rootTree` derivation
- [x] 9.2 Replace inline Python heredocs with `fix-elf-palign $out` and `hash-manifest $out` calls via nativeBuildInputs
- [x] 9.3 Replace `python3 -c "import json; ..."` status line with output from `hash-manifest` or a shell `grep -c` equivalent
- [x] 9.4 Drop `python3` from `nativeBuildInputs`, add `fix-elf-palign` and `hash-manifest`
- [x] 9.5 Move shell helpers (`mkDirs`, `mkDevSymlinks`, `mkBootPackages`, `mkStorePackages`, `mkSystemProfile`, `mkGeneratedFiles`) into this file as local `let` bindings
- [x] 9.6 Wire into `default.nix`

## 10. Extract initfs.nix

- [x] 10.1 Create `nix/redox-system/modules/build/initfs.nix` as a function taking `{ hostPkgs, pkgs, lib, config, initScriptFiles, pcidToml }` and returning the `initfs` derivation
- [x] 10.2 Wire into `default.nix`

## 11. Extract checks.nix

- [x] 11.1 Create `nix/redox-system/modules/build/checks.nix` as a function taking `{ hostPkgs, lib, rootTree, config }` and returning the `systemChecks` derivation
- [x] 11.2 Wire into `default.nix`

## 12. Extract manifest.nix

- [x] 12.1 Create `nix/redox-system/modules/build/manifest.nix` as a function taking config + build artifacts, returning `{ versionInfo, versionJson, manifestData, manifestJson, toplevel }`
- [x] 12.2 Wire into `default.nix` — `toplevel` depends on `rootTree`, `initfs`, `diskImage`, `systemChecks`

## 13. Slim down default.nix

- [x] 13.1 Remove all extracted code from `default.nix` — it should only contain: module metadata (name, inputs), imports of the sub-files, `impl` function that calls each import and assembles the output attrset
- [x] 13.2 Verify `default.nix` is under 350 lines
- [x] 13.3 `git add` all new files

## 14. Verify build correctness

- [x] 14.1 Build `rootTree` for `minimal` profile — builds successfully
- [x] 14.2 Build disk image for `minimal` profile — builds successfully
- [x] 14.3 Build `rootTree` for `graphical` profile (eval succeeds)
- [x] 14.4 Build `rootTree` for `self-hosting` profile (eval succeeds)

## 15. Smoke test VM boots

- [x] 15.1 Run `nix run .#bootTest` — boot test passes (bootloader → kernel → boot complete)
- [x] 15.2 Run `nix run .#functional-test` — boots to same state as pre-split (login prompt, pre-existing test runner issue unrelated to split)
