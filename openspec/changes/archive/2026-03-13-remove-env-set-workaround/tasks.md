## 1. Remove the patch

- [x] 1.1 Delete `nix/pkgs/userspace/patches/patch-cargo-env-set.patch`
- [x] 1.2 Remove the two-line reference (comment + patch path) at lines 395-396 of `nix/pkgs/userspace/rustc-redox.nix`

## 2. Update test comments

- [x] 2.1 Update line 1851 in self-hosting-test.nix: remove `--env-set` reference from the "root cause" comment
- [x] 2.2 Update lines 1869-1870: change "works via --env-set (CLI flag)" to describe DSO environ propagation
- [x] 2.3 Update line 1901: change failure message from "env!() works via --env-set but process env is broken" to reflect that both paths use DSO environ now
- [x] 2.4 Update line 1979: change "NOT covered by --env-set" comment to reflect this tests DSO environ under heavy fork load

## 3. Update documentation

- [x] 3.1 Update AGENTS.md line 47: remove "—`--env-set` kept as defense-in-depth" from exec() entry
- [x] 3.2 Update AGENTS.md line 183: remove `--env-set` reference from proc-macro entry
- [x] 3.3 Update AGENTS.md line 188: change cargo patches from "4 patches" to "3 patches", remove env-set from list
- [x] 3.4 Update napkin "Active Workarounds" section: move `--env-set` entry to "Stale Claims (verified removed)"

## 4. Build and validate

- [x] 4.1 Build the self-hosting-test disk image (`nix build .#redox-self-hosting-test`)
- [x] 4.2 Run the self-hosting test VM — 58/62 PASS (4 snix-compile failures are pre-existing cargo flock hang, unrelated to --env-set. All 6 env-propagation tests PASS.)
