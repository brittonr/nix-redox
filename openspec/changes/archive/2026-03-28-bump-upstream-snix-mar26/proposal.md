## Why

The upstream snix pin is at `6f7069cd68` (2026-03-22). Four days of upstream development include a build-affecting bug fix (structured_attrs additional_files keys), eval performance improvements (~20% from observer dyn dispatch removal, plus NixAttrs unboxing and path import caching), and a Nix compatibility fix for `builtins.fetch{url,tarball}` return types. Picking these up improves on-Redox build correctness and eval speed.

## What Changes

- Bump `snix-upstream-source.nix` pin from `6f7069cd68` to the latest canon commit (`34604636d7`)
- Update the vendor hash for the new source content
- Re-apply existing Redox patches on top of the new upstream code (verify they still apply cleanly)
- Verify `snix-store` default features sed still matches (upstream may change defaults)
- Run `nix flake check` and VM functional tests to confirm no regressions

## Capabilities

### New Capabilities
- `upstream-snix-pin-bump`: Covers updating the upstream snix pin, adjusting patches, and verifying the build and tests pass.

### Modified Capabilities

## Impact

- `nix/pkgs/infrastructure/snix-upstream-source.nix` — rev, hash, and possibly sed patterns
- `snix-redox/Cargo.toml` — workspace.dependencies comment referencing the upstream commit
- Nix eval performance on Redox improves (~20% from observer changes)
- `derivation_into_build_request` additional_files fix flows through to local_build.rs
