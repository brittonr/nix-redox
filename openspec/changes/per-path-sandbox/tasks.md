## 1. Validate Proxy with Simple Builds

- [x] 1.1 Create a `sandbox-test` profile variant in `nix/redox-system/profiles/` that clones self-hosting-test but with `sandbox = true` and runs only the simplest builds first (hello world, single-crate with no deps, single-crate with 1 dep). Wire it as `nix run .#sandbox-test`.
- [x] 1.2 Run `sandbox-test` and collect the first round of failures. Document each failure mode: which syscall, which flags, which path triggered the error.
- [ ] 1.3 Add `translate_open_flags()` function to `handler.rs` that explicitly maps each Redox open flag (`O_RDONLY=0x10000`, `O_CREAT=0x02000000`, `O_RDWR`, `O_TRUNC`, `O_DIRECTORY`, `O_APPEND`) to the handler's write-intent determination. Replace the current inline `wants_write` logic in `openat`.
- [ ] 1.4 Add recursive `mkdir_p` to `handler.rs` `openat`: when `O_CREAT` is set and the path is under a read-write prefix, create missing parent directories before opening the file. Only create dirs under `$out` and `$TMPDIR` — never under read-only prefixes.
- [ ] 1.5 Re-run `sandbox-test` after flag translation and mkdir fixes. All simple builds should pass.

## 2. Fix Handler Issues for Complex Builds

- [ ] 2.1 Add the full cargo build (single workspace crate with build.rs + proc-macro dep) to the `sandbox-test` profile. Run and collect failures.
- [ ] 2.2 Fix `getdents` filtering for overlapping prefixes: when `$TMPDIR` and `$out` share a common ancestor (both under `/tmp/` or `/nix/store/`), directory listings must include entries from both. Verify with a test that has `$out=/nix/store/abc` and `$TMPDIR=/tmp/snix-build-1` and lists `/`.
- [ ] 2.3 Fix `fpath` to return the correct scheme-prefixed path. Verify cargo's `--print=file-names` and rustc's `--emit=dep-info` produce correct paths through the proxy.
- [ ] 2.4 Handle `O_APPEND` flag in `write`: when the builder opens with `O_APPEND`, seek to end before each write. Cargo log files and build script output use append mode.
- [ ] 2.5 Add read timeout on real filesystem operations in the handler: if `real_file.read()` or `real_file.write()` takes more than 30 seconds, return `EIO` instead of blocking the event loop indefinitely. Use `File::set_read_timeout` where available, or wrap in a thread with a timeout.
- [ ] 2.6 Handle `fstat` for files opened with `O_CREAT` where metadata changes after initial open (size grows as builder writes). The cached `size` field must update on every write, not just at open time. Verify the current implementation handles this (it does update `fh.size` in `write` — confirm this is sufficient for cargo's file-size checks).
- [ ] 2.7 Add allow-list entries for proc-macro output directories. When a derivation's inputs include proc-macro crates, the proc-macro's output dir (under `/nix/store/`) must be on the read-only list. Verify `build_allow_list` already resolves these via `input_derivations` output paths.

## 3. Extend proxy_namespace_test.rs

- [ ] 3.1 Add test 3: fork a child, have the child call `setns(child_ns_fd)`, then open+write+close a file in a writable directory through the proxy. Parent verifies the file exists on the real filesystem.
- [ ] 3.2 Add test 4: from the child (in proxy namespace), attempt to open `/etc/passwd`. Verify `EACCES` is returned.
- [ ] 3.3 Add test 5: from the child, create a directory, write 3 files, then call `getdents` and verify all 3 files appear.
- [ ] 3.4 Add test 6: from the child, write 1KB to a file, read it back, verify byte-for-byte equality.
- [ ] 3.5 Add test 7: measure round-trip latency for 1000 sequential open+read+close operations. Print the mean and p99 latency.
- [ ] 3.6 Wire the extended `proxy_namespace_test` into the functional-test profile so it runs as part of `nix run .#functional-test`. Emit `FUNC_TEST:proxy-roundtrip:PASS/FAIL` etc.

## 4. Validate with Full Self-Hosting Suite

- [ ] 4.1 Add the 193-crate snix build and 33-crate ripgrep build to the `sandbox-test` profile. Run the full suite.
- [ ] 4.2 Fix any remaining handler issues exposed by the full crate count (common issues: cargo's `target/.cargo-lock` file, rustc writing to `deps/` alongside the output, lld creating temporary files during linking).
- [ ] 4.3 Verify proc-macro crates (serde_derive, thiserror, etc.) compile and load correctly under the proxy. The proc-macro DLL is written to `$TMPDIR/target/` and loaded by rustc from the same path — both write and read must work.
- [ ] 4.4 Verify build scripts that read source files (cc-rs reading `.c` files from input sources) work. The `build_allow_list` must include `input_sources` as read-only — confirm this path is exercised.
- [ ] 4.5 Run the full 62-test self-hosting suite with `sandbox = true`. All tests must pass.

## 5. Enable by Default

- [ ] 5.1 Remove `sandbox = false` from `nix/redox-system/profiles/self-hosting-test.nix` (delete the `/snix` block or set `sandbox = true`).
- [ ] 5.2 Remove `sandbox = false` from `nix/redox-system/profiles/parallel-build-test.nix` if present.
- [ ] 5.3 Run the full self-hosting test suite (`nix run .#self-hosting-test`) and verify all 62 tests pass.
- [ ] 5.4 Run the functional test suite (`nix run .#functional-test`) and verify no regressions (the sandbox-related functional tests should still pass).
- [ ] 5.5 Delete the separate `sandbox-test` profile (no longer needed — self-hosting-test covers it).
- [ ] 5.6 Update `sandbox.rs` module doc comment to reflect that proxy is the default path, not experimental.
- [ ] 5.7 Update `AGENTS.md` with any new build knowledge discovered during this change.
