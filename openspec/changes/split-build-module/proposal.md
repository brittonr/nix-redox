## Why

`nix/redox-system/modules/build/default.nix` is a 2007-line monolith that handles package layout, init script generation, PCI driver registry, ELF patching, manifest hashing, system checks, initfs assembly, disk image composition, and version tracking — all in one file with three languages (Nix, bash, Python) interleaved as heredocs. It's the hardest file to change, the riskiest to break, and the most painful to review. Splitting it into focused modules makes each concern testable and reviewable in isolation.

## What Changes

- Extract the rootTree assembly (package copying, store layout, system profile symlinks, generated files) into `root-tree.nix`
- Extract initfs derivation into `initfs.nix`
- Extract PCI driver registry and pcid.toml generation into `pcid.nix`
- Extract init.d script rendering (numbered scripts, structured services) into `init-scripts.nix`
- Extract manifest/version/BLAKE3 hashing into `manifest.nix`
- Extract systemChecks derivation into `checks.nix`
- Extract inline Python ELF p_align fixer into a standalone `fix-elf-palign.py` script invoked by derivation
- Extract inline Python BLAKE3 manifest hasher into a standalone `hash-manifest.py` script
- Reduce `build/default.nix` to a thin orchestrator that imports the above and wires inputs to outputs
- No behavioral changes — identical `rootTree`, `initfs`, `diskImage`, `toplevel` outputs

## Capabilities

### New Capabilities
- `build-module-decomposition`: Structural split of the build module into focused sub-modules with stable interfaces between them

### Modified Capabilities

## Impact

- `nix/redox-system/modules/build/default.nix` — rewritten to thin orchestrator (~200-300 lines)
- New files under `nix/redox-system/modules/build/`: `root-tree.nix`, `initfs.nix`, `pcid.nix`, `init-scripts.nix`, `manifest.nix`, `checks.nix`, `fix-elf-palign.py`, `hash-manifest.py`
- All existing profiles, tests, and flake outputs are unchanged — they consume `build.impl` which returns the same attrset
- `treefmt` / `git-hooks` excludes may need updating if the new `.py` files contain heredoc-unfriendly patterns
