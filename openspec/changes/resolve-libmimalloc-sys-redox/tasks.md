**Status: COMPLETE** — the allocator-path change is validated by a focused `snix-compile-test` pass (7/7) and a full `self-hosting-test` pass (78/78) on 2026-04-09.

## 1. Capture the focused `libmimalloc-sys` baseline

- [x] 1.1 Attach the focused `snix-compile-test` evidence under this change, including the durable capture path and the exact allocator compile failure lines
- [x] 1.2 Record the current self-hosting baseline relationship: exact `c6a29e00` rerun is `77/78`, focused allocator rerun isolates the remaining blocker in `libmimalloc-sys`
- [x] 1.3 Confirm whether the focused runner itself should be committed as part of this change or only used as a temporary investigation harness

## 2. Trace allocator selection in the self-built `snix` graph

- [x] 2.1 Identify which crate or feature currently pulls `libmimalloc-sys` into `/usr/src/snix-redox/build.nix`
- [x] 2.2 Determine whether Redox can select a non-mimalloc allocator path without changing `snix` CLI-visible behavior
- [x] 2.3 Safe feature/dependency selection exists, so no Redox-specific mimalloc C patch is needed for this step

## 3. Land a Redox-safe allocator fix

- [x] 3.1 Implement the chosen allocator fix in the relevant package, dependency, or vendor path
- [x] 3.2 Ensure the self-build source bundle and any host-side package build use the same allocator fix so guest rebuilds match the evaluated source tree
- [x] 3.3 Re-run `nix run .#snix-compile-test -- --verbose` and capture durable PASS evidence for `snix-compile`, `snix-binary-runs`, and `snix-eval-works`
  - PASS capture: `/var/tmp/redox-self-hosting-captures/20260409T115513-snix-compile-test/`
  - attached excerpt: `evidence/2026-04-09-snix-compile-focus-pass.excerpt.txt`

## 4. Rebaseline and document

- [x] 4.1 Re-run `nix run .#self-hosting-test -- --verbose` after the focused pass and confirm whether `snix-compile` is no longer the blocker
  - first rerun on the old 2400s timeout stopped at 70 PASS lines while `snix-compile` was still running (`/var/tmp/redox-self-hosting-captures/20260409T125126-self-hosting-test/`)
  - after bumping `self-hosting-test` timeout to 4800s, the full rerun passed 78/78 at `/var/tmp/redox-self-hosting-captures/20260409T133254-self-hosting-test/`
- [x] 4.2 Update `AGENTS.md`, `.agent/napkin.md`, and the active OpenSpec evidence with the final root cause and chosen fix
- [x] 4.3 Close or narrow `fix-snix-build-gaps` tasks 6.3 / 7.4 once the new allocator-focused evidence justifies it
