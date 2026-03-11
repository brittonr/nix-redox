## 1. Launcher Binary

- [x] 1.1 Create `nix/pkgs/userspace/lld-wrapper.nix` — a compiled Rust binary that spawns a 16MB-stack thread, then `exec()`s lld with all forwarded arguments from that thread. Follow the `cc-wrapper-redox.nix` `mkBinary` pattern. On exec failure, print error to stderr and exit 1.
- [x] 1.2 Add `lld-wrapper` to the self-hosting package set so it gets installed into `/nix/system/profile/bin/lld-wrapper` on Redox.

## 2. Bash CC Wrapper Integration

- [x] 2.1 In `redox-sysroot.nix`, change the bash cc wrapper to invoke `lld-wrapper` instead of `$LLD` directly for both executable and shared-library link paths. Keep the same argument structure (CRT objects, library flags, etc.).

## 3. Compiled CC Wrapper Update

- [x] 3.1 In `cc-wrapper-redox.nix`, replace the `CommandExt::exec()` call from main with a spawn-thread pattern: spawn a 16MB-stack thread that calls `exec()`, then join/wait from main.

## 4. Validation

- [x] 4.1 Build a disk image with the updated cc wrapper and lld-wrapper included.
- [ ] 4.2 Boot the image and run a JOBS=1 self-hosting build to confirm no regression.
- [ ] 4.3 Run JOBS=2 self-hosting build of `fn main() { println!("hello"); }` — confirm both linker invocations succeed without `abort()` crash.
- [ ] 4.4 Run JOBS=2 cargo build of a multi-crate project (e.g., ripgrep) to validate under real parallel workload.

## 5. Cleanup

- [ ] 5.1 Update AGENTS.md: change the "CARGO_BUILD_JOBS > 1 hangs" note to reflect the fix (linker stack overflow, resolved by lld-wrapper).
