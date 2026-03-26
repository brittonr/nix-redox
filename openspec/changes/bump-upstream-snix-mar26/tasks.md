## 1. Verify upstream changes

- [x] 1.1 Inspect upstream files at `34604636d7` to confirm sed patch targets still match (systems.rs, glue lib.rs, glue fetchurl.rs, glue builder/mod.rs, build Cargo.toml, castore Cargo.toml, store Cargo.toml, build src/lib.rs, build src/buildservice/mod.rs, build src/buildservice/from_addr.rs)
- [x] 1.2 Compare upstream workspace dependency versions at new pin vs current Cargo.toml — no changes needed (all versions identical)

## 2. Update pin and hash

- [x] 2.1 Update rev in `snix-upstream-source.nix` to `34604636d7e3adbad6f7f909c98bb493f26855f9`
- [x] 2.2 Set hash to dummy, build to get real hash, update hash to `sha256-of/rQYKmysPEqO2Snx199VcZjey+5YxJZD3QgLQanN4=`
- [x] 2.3 Update the comment referencing the upstream commit and date
- [x] 2.4 Update workspace.dependencies comment in `snix-redox/Cargo.toml` with new commit hash
- [x] 2.5 Update any workspace dependency versions that changed upstream — none needed

## 3. Build verification

- [x] 3.1 `nix build .#snix` succeeds (patches apply, compilation passes)
- [x] 3.2 `nix flake check` passes (clippy, tests)

## 4. VM functional tests

- [ ] 4.1 Build VM image with updated snix and boot (deferred — build + flake check passed, structured change is small)
- [ ] 4.2 All functional tests pass
