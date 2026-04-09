# Evidence for `resolve-libmimalloc-sys-redox`

Committed evidence captured while isolating the remaining `snix-compile` blocker.
The durable raw logs live outside the repo; the checked-in file below is a compact excerpt.

## Focused `snix-compile-test` allocator failure baseline

- Capture dir: `/var/tmp/redox-self-hosting-captures/20260408T205802-snix-compile-focus/`
- Commit under test: `e3274fa4f0247e79353a8553fccba281b13d2617`
- Command:
  - `nix run .#snix-compile-test -- --verbose`
- Raw logs:
  - `snix-compile-test.log`
  - `snix-compile-test.text.log`
  - `markers.txt`
  - `snix-window.txt`
- Committed excerpt:
  - `2026-04-08-snix-compile-focus-libmimalloc-sys.excerpt.txt`

### What the excerpt shows

- The focused runner reaches `Compiling libmimalloc-sys v0.1.44`.
- The failing C file is `c_src/mimalloc/v2/src/static.c`.
- Redox clang/sysroot rejects mimalloc atomics with errors such as:
  - `address argument to atomic operation must be a pointer to integer, pointer or supported floating point type ('_Atomic(int64_t) *' invalid)`
  - `address argument to atomic operation must be a pointer to a trivially-copyable type ('_Atomic(mi_block_t *) *' invalid)`
- `cc-rs` reports the failing compile command directly.
- The focused test still reports:
  - `FUNC_TEST:snix-binary-runs:PASS`
  - `FUNC_TEST:snix-eval-works:PASS`
- Final focused verdict from this run:
  - `Passed:  6`
  - `Failed:  1`
  - `Total:   7`
  - failed test: `snix-compile`

## Baseline relationship to the earlier exact rerun

The current allocator-focused run narrows the remaining blocker from the earlier exact `c6a29e00` full-suite baseline recorded under `../fix-snix-build-gaps/evidence/`:

- exact `c6a29e00` full rerun: `77/78` passed, with `snix-compile` as the lone failure
- focused `snix-compile-test` rerun: isolates the failing self-build to `libmimalloc-sys` C compilation on Redox

This means the unresolved self-hosting gap is no longer just “`snix-compile` fails somewhere in the workspace”; it is specifically the allocator path selected for the self-built derivation.

## Focused rerun after removing normal mimalloc deps

- Capture dir: `/var/tmp/redox-self-hosting-captures/20260408T213428-snix-compile-focus-pass`
- Command:
  - `nix run .#snix-compile-test -- --verbose`
- Raw logs:
  - `snix-compile-test.log`
  - `host-monitor.log`
- Committed excerpt:
  - `2026-04-08-snix-compile-focus-post-mimalloc.excerpt.txt`

### What the rerun shows

- The self-build gets past the old `libmimalloc-sys` / `static.c` failure point.
- `FUNC_TEST:snix-binary-runs:PASS` and `FUNC_TEST:snix-eval-works:PASS` still hold.
- The remaining failure moves later to `snix-castore`'s build script, which exits with `Error: Custom { kind: Other, error: "protoc failed: " }`.
- The host-side monitor shows Cloud Hypervisor stayed busy until the late failure, so the quiet serial phase was compilation time rather than a guest hang.

This rerun is the evidence that the allocator-path change worked well enough to expose the next blocker.

## Focused runner status

The focused runner is part of this change, not a throwaway harness.
It is wired into `nix/flake-modules/system.nix` as `.#snix-compile-test` and uses `nix/redox-system/profiles/snix-compile-test.nix`.
That keeps allocator experiments on the same self-hosting image and source-bundle path as the full suite while cutting out the 70 earlier smoke tests.
