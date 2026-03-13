## 1. Build and run self-hosting-test

- [x] 1.1 Build `nix build .#self-hosting-test` — captures full disk image with self-hosting profile
- [x] 1.2 Run `nix run .#self-hosting-test` and capture serial log — 62/62 PASS in 998s
- [x] 1.3 Check `parallel-jobs2` result in serial log — PASS. Skipping section 2 (no fix needed)

## 2. Diagnose and fix parallel-jobs2 crash (only if 1.3 shows FAIL)

- [x] 2.1 N/A — parallel-jobs2 PASS, crash already fixed by fork-lock + lld-wrapper
- [x] 2.2 N/A
- [x] 2.3 N/A
- [x] 2.4 N/A

## 3. Archive investigation changes

- [x] 3.1 Archive `cargo-parallel-hang-investigation` — all 27 tasks checked off, 2 delta specs synced, moved to archive
- [x] 3.2 Archive `fix-remaining-os-bugs` — all 30 tasks checked off, 3 delta specs synced, moved to archive

## 4. Update documentation

- [x] 4.1 Correct napkin entry for "Self-hosting test parallel-jobs2 linker crash" — moved to stale claims, root cause was fork-lock bug not stack
- [x] 4.2 Correct napkin claim that cc wrapper runs "lld inside clang" — corrected in stale claims entry: cc wrapper calls lld-wrapper directly
- [x] 4.3 Verify AGENTS.md parallel build section is accurate — fork-lock, lld-wrapper, CLONE_LOCK all correctly documented
- [x] 4.4 Commit all changes
