# Autoresearch ideas

Actionable paths only. Detailed tried/lost history lives in `autoresearch.md`.

- Re-test the mildly promising `unit2nix` lazy test/clippy graph construction patch with a clean control/experiment pair. Use the real sibling input path, not an in-repo vendored copy. Previous clean override-input controls were ~7210-7216ms; patched reruns were ~7036-7182ms, low confidence but not dead.
- If changing the optimization target later, create a separate rebuild-focused experiment session. GPT GUID/CRC normalization made `nix build .#redox-functional-smoke-test --rebuild --no-link` viable again, but that is a different metric than the current normal edit/build/boot smoke loop.
- Explore only narrow smoke-profile trims that preserve the real boot/test path. Known safe keeps: exclude `rtcd`, `ptyd`, `ipcd`, `acpid`, `lived`; use `storageDrivers = [ "virtio-blkd" ]`; use `networkDrivers = [ ]`; no dash symlink; no smoke shell aliases; empty smoke MOTD; narrowed smoke `extraDirectories`. Try new daemon/package/config trims one at a time with same-file controls.
- Runtime disk staging needs a genuinely different writable COW approach before retrying. Already stale: qcow2 backing files with current CH, read-only raw disk, `cp --sparse=always`, and `cp --reflink=auto` for the mutable runtime disk copy.

Do not re-test now: monolithic smoke `base`, smoke-only `baseSmokePerCrate`, Redox-side `members = [ member ]` hints, global unit2nix test/clippy disabling, `base.src` extraction, random package input pruning including `bottom-src`, smaller smoke/ESP images, `/power.acpiEnable = false`, hwd removal/initSkip/direct-pcid replacement, removing `/usr/bin` from smoke dirs, removing `zerod`, rootTree reflink copy, final-image `mv`, ESP payload slimming, direct-to-output image creation, larger-block disk `dd`, incremental serial polling, CH `image_type=raw` hint, minimal smoke boot banner, or `bootloaderPerCrate` on this CH-only benchmark.
