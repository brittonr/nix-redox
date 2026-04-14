# Napkin — Redox OS Build System

Active corrections and recurring mistakes. Permanent knowledge lives in AGENTS.md.

## Recurring Mistakes

### Package partitioning uses derivation references, not name strings
- Boot vs managed partition uses `samePackage` (outPath equality), never pname/parseDrvName.
- `bootPackages` is built from `pkgs.*` references directly (pkgs.base, pkgs.ion, etc.).
- `selfHostingPackages` same pattern — pkgs.redox-rustc, pkgs.redox-llvm, etc.
- `managedPackages` = systemPackages filtered by `!isBootPkg` (derivation identity).
- If a package changes pname/name metadata, nothing breaks — we reference the derivation, not its name.
- Old `bootEssentialNames` string list eliminated entirely.

### New files must be `git add`ed for flakes
- Every session. New `.nix` or `.rs` files invisible to `nix build` until tracked.

### Nix `''` string terminators
- `''` in Python code, `echo ''`, `get('key', '')` — all terminate the Nix string.
- Use `""`, `echo ""`, `str()` respectively.
- Comments containing `''` also break — reword to avoid consecutive single quotes.
- Inside Nix `''` strings, bash `${var}` needs `''${var}` or Nix tries to interpolate it at evaluation time.

### Heredoc indentation in Nix `''` strings
- ONE column-0 line breaks ALL heredoc terminators. Every line needs N+ spaces for N-space stripping.
- If a Nix shell string already has a column-0 heredoc terminator (for example `PATCH`), any new heredoc terminators you add must also be column 0 in the source file. I forgot this in `snix-upstream-source.nix`, and the shell dumped later `cat` commands into `build.rs`.
- `nix fmt` can silently re-indent and break heredocs. Verify after formatting.
- Inline Python in Nix strings breaks too — extract to .py files instead.

### Vendor hash must update in BOTH files
- `snix.nix` AND `snix-source-bundle.nix` need the same hash when Cargo.lock changes.

### OpenSSL 3 cross-build needs two Redox-specific workarounds
- The first `openssl3-redox` attempt failed in `crypto/core_namemap.c` because relibc's `stdatomic.h` trips clang on `_Atomic(int) *`. Fix: add `-D__STDC_NO_ATOMICS__=1` so OpenSSL takes its GCC/clang `__atomic` fallback.
- The next failure was `apps/openssl` linking against static `libzstd.a` without libc symbols resolved. We don't need the CLI tool for the package, only the libraries. Build `build_generated libcrypto.a libssl.a` and install headers/libs manually instead of running the full OpenSSL build/install.

### OpenSSH 9.8p1 on Redox needs several packaging workarounds
- `./configure` failed its libcrypto probe until I exported `LIBS="-lz -lzstd"`; the static OpenSSL 3 package does not bring those deps in automatically during OpenSSH's link test.
- The upstream Redox patch still leaves `openbsd-compat/getrrsetbyname.c` calling `res_query()`, but relibc has no resolver API. A tiny Redox-local `res_query(...){ return -1; }` stub in the package source is enough to keep the non-goal DNS RR path compiling.
- `UsePAM no` in `sshd_config` aborts the Redox build unless `servconf.c` stops treating `usepam` as `sUnsupported`. Rewriting that keyword entry to `sIgnore` keeps the config line harmless.
- `make install` tries to install `ssh-keysign` with mode `4711`; Nix store outputs reject setuid bits. Patch the generated `Makefile` to install it as `0755` inside the package output.
- OpenSSH helper binaries must stay under `/usr/libexec` in the package output. If the package flattening step moves everything to `$out/bin`, guest sshd exits with `/usr/libexec/sshd-session does not exist`.
- The rootTree -> RedoxFS image copy path (`chmod -R u+w root/`) widens generated private key modes to `0644`. Fix them back to `0600` in `make-redoxfs-image.nix`; guest-side `chmod` is not reliable because `chmod` may be absent from the Redox test profile.

### Verify the exact commit, not a later dirty tree
- I claimed a `77/78` full-suite baseline from earlier logs, but an exact rerun of commit `c6a29e00` in a detached worktree only reached `70/70` before the 2400s timeout.
- When a review asks for evidence against a specific commit, rerun that exact commit in a worktree (`git worktree add --detach /tmp/... <commit>`) instead of assuming later docs-only commits or dirty-tree edits match the earlier run.

### Archiving OpenSpec changes needs a path sweep
- Moving a change under `openspec/changes/archive/<date>-.../` leaves stale evidence paths behind in `tasks.md`, `evidence/README.md`, and any AGENTS notes that pointed at the active change path.
- After archiving, grep for the old `openspec/changes/<name>/` path and rewrite the surviving references before committing the archive.

### Self-hosting vs self-hosting-test images are not interchangeable
- I tried to reproduce `snix-compile` in the plain `self-hosting` image and got `/usr/src/snix-redox/build-snix.sh: No such file or directory`.
- That was a false lead: the source bundle only exists in the `self-hosting-test` image. Use the actual test image when reproducing fixture failures tied to `/usr/src/*` bundles.

### Exact `snix-compile` failure is later than proc-macro2/quote
- Live rerun on the `self-hosting-test` image reached `tower-http` before failing, not just the initial `proc-macro2` / `quote` lines seen in the short excerpt.
- The decisive errors were `E0463: can't find crate for tracing`, `futures_util`, and `tower` while rustc was invoked with matching `--extern ... .rmeta` paths, followed by `fatal runtime error: failed to initiate panic, error 0, aborting`.
- Keep this in mind when debugging: the remaining bug is likely in cargo/rustc build mode, dependency metadata visibility, or panic handling during the big workspace build, not just in the source bundle plumbing.

### Pueue VM test logs are not durable enough for evidence by themselves
- I lost the final result of a `self-hosting-test` rerun because the pueue task record and `task_logs/15.log` disappeared before I extracted the tail.
- For long Redox VM runs, tee stdout/stderr to a durable file under `/var/tmp/redox-self-hosting-captures/<timestamp>/` and keep metadata (`git status`, patch, exit code) beside the log.
- Treat pueue output as convenience for monitoring, not as the only evidence artifact.
- `vm-tests` pueue group can be paused while still accepting `start_immediately` tasks; `pueue status` then shows confusing state, and `nix run` may stall before boot on `waiting for the big garbage collector lock...`. Check group pause state and host Nix GC lock before treating the VM test as a guest-side failure.
- `mk-vm-test` uses `mktemp -d` on the host and copies the full disk image there before boot. For multi-GB self-hosting images, set `TMPDIR=/var/tmp` on the host if `/tmp` is a tmpfs or otherwise space-constrained, or the run can fail early with `cp: error writing ... redox.img: No space left on device` before the VM even starts.

### Focused `snix-compile` test exposed a new concrete blocker
- Isolating `snix-compile` into a focused VM test removed the 2400s full-suite timeout and reproduced the failure in ~1169s with durable logs.
- The current blocker is no longer the earlier `tower-http` / `E0463` symptom: the build now reaches `libmimalloc-sys` C compilation and fails in `c_src/mimalloc/v2/src/static.c` with Clang errors like `address argument to atomic operation must be a pointer to a trivially-copyable type ('_Atomic(mi_block_t *) *' invalid)`.
- The focused run still reports `FUNC_TEST:snix-binary-exists:PASS`, `FUNC_TEST:snix-binary-runs:PASS`, and `FUNC_TEST:snix-eval-works:PASS` for the profile's installed `/bin/snix`; only the self-compiled derivation fails.
- Durable evidence path: `/var/tmp/redox-self-hosting-captures/20260408T205802-snix-compile-focus/`.

### `snix-redox/upstream` is a read-only symlink into the Nix store
- I tried to edit `snix-redox/upstream/build/Cargo.toml` directly and hit a dead end because `snix-redox/upstream -> ../result-snix-upstream` points into a read-only store path.
- Fix upstream workspace manifests in `nix/pkgs/infrastructure/snix-upstream-source.nix`, then rebuild the upstream source derivation and repoint the local `snix-redox/upstream` symlink before regenerating build plans.

### Local host-side `cargo test` for `snix-redox` has two easy validation traps
- Running `cargo test` in `snix-redox/` inherited the Redox target config and immediately fell into `zstd-sys` cross-build failures (`clang --target=x86_64-unknown-redox` against host glibc headers).
- Even with `--target x86_64-unknown-linux-gnu` and `PROTOC` set, upstream build scripts still expect proto paths under `snix/.../protos/*`, so host-side validation can fail before reaching our Rust edits.
- Practical fallback: use `rustfmt --config skip_children=true` on the touched Rust files for a fast syntax check, and treat full cargo validation as needing the repo's intended Nix/snix build environment.
- Redox-only modules behind `#[cfg(target_os = "redox")]` are invisible to the Linux-target host tests. Do not mark Redox scheme tasks done until `x86_64-unknown-redox` code path is compiled or exercised.
- The reliable host-side path is now `./scripts/validate-snix-redox-host.sh`, which sets `PROTO_ROOT=$PWD/upstream`, finds `protoc`, and forces `--target x86_64-unknown-linux-gnu`.

### Remote cache VM test wants `eth0`, not interface discovery
- `network-install-test.nix` originally tried to discover the first netcfg interface with `ls /scheme/netcfg/ifaces`, but under Ion startup that loop was flaky and could burn the whole timeout without emitting FUNC_TEST lines.
- Hardcode `eth0` and wait on `/scheme/netcfg/ifaces/eth0/addr/list`; `netcfg-auto` reports the guest interface as `eth0` in the successful run.
- Startup scripts still need `let PATH = "/nix/system/profile/bin:/bin:/usr/bin"` + `export PATH` at the top before using helper commands like `sleep`.

### Self-built `snix` needs the same no-CA patch as the packaged binary
- The focused rerun at `/var/tmp/redox-self-hosting-captures/20260409T110038-snix-compile-test/` showed `FUNC_TEST:snix-compile:PASS` and `FUNC_TEST:snix-binary-runs:PASS`, but `FUNC_TEST:snix-eval-works:FAIL` because the self-built binary panicked in `upstream/glue/src/fetchers/mod.rs` with `Client::new(): reqwest::Error { kind: Builder, source: General("No CA certificates were loaded from the system") }`.
- `src/main.rs` setting `SSL_CERT_FILE=/dev/null` is not enough for this upstream reqwest path. The packaged host build already patches `snix-glue` via `patch-snix-fetcher-no-tls-panic.py`; the self-hosted source bundle must apply the same patch in `nix/pkgs/infrastructure/snix-upstream-source.nix` or guest-built `snix eval` will still abort.
- After moving that patch into the upstream source bundle, the old package-level patch started double-applying and failing. `patch-snix-fetcher-no-tls-panic.py` needs to be idempotent because both the packaged build and the source bundle may run it against the same source tree.

### Full self-hosting timeout was stale after the focused snix-compile fix
- `nix run .#self-hosting-test -- --verbose` at `/var/tmp/redox-self-hosting-captures/20260409T125130-self-hosting-test/` no longer failed in `snix-compile`; it hit the suite timeout with 70 PASS lines printed while `snix-compile` was still in progress.
- The focused passing rerun at `/var/tmp/redox-self-hosting-captures/20260409T115513-snix-compile-test/` took 3089s by itself, so the full suite's old 2400s timeout can never finish. Keep `self-hosting-test` at 4800s or higher unless the guest self-compile gets materially faster.

### Focused self-compile tests go silent if they capture `snix build` into a shell variable
- `OUTPUT=$(/bin/snix build --file ... 2>/tmp/snix-compile-err)` hides all progress until the build exits, so long guest compiles look hung even when Cloud Hypervisor is busy.
- Fix: run `snix build` in the background, `wait` on its PID, and emit a periodic heartbeat that reports elapsed time plus `/tmp/snix-compile-{output,err}` sizes and the latest matching progress line.
- Patch both `nix/redox-system/profiles/snix-compile-test.nix` and `nix/redox-system/profiles/self-hosting-test.nix` so focused and full self-hosting runs behave the same.
- A host-side sidecar log (`host-monitor.log`) sampling the Cloud Hypervisor PID, `/proc/<pid>/io`, and serial log `stat` once per minute is enough to tell “quiet but compiling” from “actually dead”.

### Removing normal mimalloc deps exposed the next blocker
- After dropping unused `mimalloc` normal deps from upstream `snix-build`, `snix-store`, and `nix-compat`, the focused rerun got past `libmimalloc-sys` and failed later in `snix-castore`'s build script instead.
- The new failure is `Error: Custom { kind: Other, error: "protoc failed: " }` from `snix-castore` during the guest self-build.
- This means the allocator change did its job; the next investigation should focus on guest-side `protoc` / proto path setup, not mimalloc.
- After fixing the proto step with pregenerated descriptor sets, the next late failure was self-inflicted: plain `cargo build` in `build-snix.sh` also builds the extra `proxy_namespace_test` [[bin]] target from Cargo.toml, but the source bundle does not copy `tests/redox/proxy_namespace_test.rs`. Build only `--bin snix`, and make the host-side bundle audit check the `snix` bin path plus pregenerated `.bin` descriptor sets.

### `cp -r dir/*` drops dotfiles
- Use `cp -r dir/.` to copy ALL contents including dotfiles.
- `.cargo/config.toml` silently lost when `/*` was used.

### Toplevel `/etc` checks are nested under `etc/etc/*`
- `manifest.nix` links the standalone etc derivation at `$toplevel/etc`, and that derivation itself stores files as `etc/passwd`, `etc/profile`, etc.
- Artifact tests for `artifact = "toplevel"` must check `etc/etc/passwd` (or similar), not `etc/passwd`.

### Rootfs startup and networking service tests must match TOML unit files
- `usr/lib/init.d/*.service` now stores `cmd = "..."` and `type = "..."` fields, not legacy shell lines like `notify /bin/smolnetd`.

### Package-only rebuilds can break later tool lookups inside the same bash block
- I assumed a pre-started `/nix/system/profile/bin/bash -c '...'` would keep later `grep` checks safe after a package-only rebuild. Wrong: once the profile symlink flips, later PATH lookups inside that same shell can still fail because the helper binary vanished.
- For post-rebuild assertions, prefer shell builtins/pattern matching (`case`, `[[ ... == *...* ]]`) or resolve absolute tool paths before the rebuild.
- Non-userutils startup is emitted as `99_startup.service` with `cmd = "/startup.sh"` and `type = "oneshot_async"`; `etc/init.toml` can stay empty.

### Native guest kernel rebuild should use prebuilt trampoline blobs, not guest nasm
- In `kernel-rebuild-test`, appending `pkgs.nasm` to `/environment.systemPackages` still left `/nix/system/profile/bin/nasm` missing in the guest, so trying to package guest nasm was wrong direction.
- Correct long-term fix: patch kernel `build.rs` to support `REDOX_KERNEL_USE_PREBUILT_TRAMPOLINE`, generate `src/asm/{x86,x86_64}/trampoline.bin` during host-side source prep, and set that env var in the guest native builder.
- This keeps host/cross builds using real `nasm`, while native Redox guest rebuilds use deterministic prebuilt blobs from the same asm sources.
- After this fix, the focused native rebuild gets past the old trampoline blocker and fails later at kernel link, so the nasm issue is genuinely cleared.

### Rebuild VM test traps I hit this pass
- I forgot `let PATH = "/nix/system/profile/bin:/bin:/usr/bin"; export PATH` at the top of a startup-script test, then blamed bash when `grep`/`sed` were just missing from PATH.
- I put single quotes inside an Ion `bash -c '...'` block (`grep '"id"' ...`) and got an Ion parse error instead of a bash error. Use double quotes inside the bash snippet.
- `pwd -P` on Redox did not prove `/nix/system/current` target reliably in the VM; `ls -ld /nix/system/current | grep ...` did.
- I initially blamed rebuild when `/etc/hostname` stayed old, but activation order was wrong: `/etc/static` symlink-farm setup ran after manifest-derived writes and replaced the freshly-written file with the stale symlink target. Fix: setup `/etc/static` first, then replace derived-file symlinks with regular files.
- Rootfs startup scripts still need `let PATH = "/nix/system/profile/bin:/bin:/usr/bin"` + `export PATH` at the top. I forgot this in `stored-lazy-test.nix`, and `grep` failed even though extrautils was installed.
- `stored` lazy extraction must read `<store-hash>.narinfo` and follow its `URL:` field; local guest caches can store NARs under paths like `/nix/cache/nar/<sha>.nar.zst`, not `<store-hash>.nar.*`.
- When I added a new `snix-redox` bin target (`stored`), `cargo check --bins` passed but `self.packages.snix` still omitted it until I reran `snix-redox/regenerate-build-plan.sh`.
- For init `type = "daemon"` services on Redox, readiness is only one zero byte on `INIT_NOTIFY`; no full daemon crate needed if the binary can write that byte directly.

### `mod build_proxy` must be in BOTH lib.rs AND main.rs
- snix-redox has separate lib and bin crates with their own module trees.

### Nix derivation caching vs. dirty flake tree
- `git add` alone doesn't force re-evaluation if content hash hasn't changed.
- Check with `nix eval --raw '.#pkg.drvPath'` before and after to confirm drv changed.

## UEFI liveMode Memory Limit

### N150 can't allocate >~3GB contiguous UEFI memory for liveMode
- `diskSizeMB = 4096` → 3892 MiB RedoxFS → bootloader panics: "out of resources" (Status 0x8000000000000009)
- UEFI `AllocatePages` needs contiguous conventional memory — firmware memory map is fragmented
- 1024 MiB works, 2560 MiB (2470 MiB RedoxFS) works, 4096 MiB fails
- Root tree actual data was 1.6GB — the 4GB disk was massively oversized
- Fix: size `diskSizeMB` to actual data + ~50% headroom, not raw toolchain package sizes
- The toolchain packages (rustc 426M + llvm 802M + sysroot 32M) overlap/share files in the root tree

## Kernel Two-Phase Build

### Cargo fingerprint leakage across Nix derivations
- The two-phase kernel build (kernelDeps → kernel) recompiles ~11 crates in phase 2 instead of just 1.
- Root cause: cargo's fingerprints for build-script crates use mtime-based freshness checks. Nix store normalizes all timestamps to epoch (1), and even `touch` doesn't fully fix it because source files in vendor-combined retain epoch mtime while target/ files get a new time.
- Affected crates: serde_core, serde, zerocopy, ahash, rmm, toml_datetime, serde_spanned, toml_edit, toml, hashbrown — all have build scripts or depend on crates with build scripts.
- Despite the leakage, phase 2 takes ~5.5s vs ~12s full build = ~2x speedup.
- `dontFixup = true` on kernelDeps is critical — patchelf modifies build script binaries, breaking fingerprints completely.
- Must delete `.cargo-lock` files from copied target dir (cargo can't re-acquire stale locks).
- Must also delete Cargo.lock's git source for fdt (patched to path dep) so cargo doesn't re-lock.

## igcd (I225/I226) Driver Debugging

### RCTL_UPE (promiscuous mode) causes boot deadlock on N150
- Adding RCTL_UPE flag to RCTL register causes the NIC to receive ALL network traffic
- The resulting interrupt storm during boot (before the event loop runs) deadlocks init
- Symptom: boot hangs at "fbbootlogd: mapped display" — same as the RSDP missing hang
- Root cause: igcd's init enables RCTL before the IRQ event loop is running, so incoming packets generate interrupts that are never acknowledged, causing IRQ storm
- Fix: do NOT enable RCTL_UPE; use MAC filter only (ensure RAL0/RAH0 are correct)

### redox-log file output is broken during initfs boot
- `common::setup_logging("net", "pci", &name, Info, Info)` creates log files at `/scheme/logging/net/pci/<name>.log` but they are always 0 bytes
- The logging: scheme exists and directories are created, but no data is ever written
- Even after ping activity (which calls write_packet/read_packet), log file stays empty
- Workaround needed: can't use log::info!/debug!/trace! for diagnostics during initfs boot
- Alternative approaches for initfs driver debugging:
  - Write to `/scheme/debug` directly (kernel serial, but AGENTS.md says reads don't work from Ion)
  - Modify driver-network to support a "diag" read path on the scheme itself
  - Use kernel syscall_debug tracer
  - CANNOT write to `/tmp/` (doesn't exist during initfs), `/scheme/fbbootlog` (deadlocks through initnsmgr)

### initnsmgr deadlock during driver init (scheme I/O)
- Any file: I/O from igcd during init (before scheme registration) can deadlock
- This includes: opening fbbootlog scheme, writing to files, debug-level logging (too many writes)
- Root cause: initnsmgr is single-threaded, and pcid-spawner → igcd init path goes through initnsmgr
- Safe: `log::info!` at default rate (4-6 calls); NOT safe: `log::debug!` (dozens of calls), file opens

### I225/I226 RDT must be written AFTER RXDCTL enable
- The I225/I226 silently ignores writes to RDT before RXDCTL.ENABLE is set
- Symptom: RDH=0 RDT=0 after boot — ring empty, no RX possible
- Fix: set RDH=0, enable RXDCTL, wait for enable, enable RCTL, THEN set RDT=N-1
- Same applies to TDT (write after TXDCTL enable) for consistency
- Discovered via diag scheme: `cat /scheme/network.pci-0000-03-00.0_igc/diag`

### Driver diag scheme path — only reliable diagnostic on Redox
- Added "diag" read path to driver-network via patch-driver-network-diag.py
- `cat /scheme/network.*/diag` reads registers from the running driver's own event loop
- No initnsmgr involvement, no logging infrastructure dependency
- Returns: CTRL, STATUS, RCTL, TCTL, IMS, RXDCTL, TXDCTL, SRRCTL, RDH, RDT, TDH, TDT, RAL, RAH, ICR, MAC
- This is the ONLY reliable way to get driver state — log files are always empty, fbbootlog deadlocks

### smolnetd netcfg scheme hardcodes interface as "eth0"
- smolnetd's `mk_root_node` in `netstack/src/scheme/netcfg/mod.rs` uses hardcoded `"eth0"`
- netcfg-setup must use `eth0` for configuration, not PCI-path names
- `discover_first_interface()` must fall back to checking `/scheme/netcfg/ifaces/eth0/mac`
- The netcfg scheme does NOT support directory listing (getdents) — `read_dir` always fails

### netcfg-setup CIDR double-prefix bug
- `apply_static_config` appended `/prefix` to addresses already containing `/24`
- Result: `192.168.1.100/24/24` → smolnetd rejects silently
- Fix: check if address already contains `/` before appending prefix

### init-scripts.nix strips command paths via baseNameOf
- `renderServiceToml` uses `builtins.baseNameOf svc.command` → strips `/bin/` prefix
- After rootfs switchroot, init's PATH = `/usr/bin` (NOT `/bin`)
- Commands at `/bin/` are unreachable without full path
- Fix: preserve full path when command starts with `/`

### smolnetd readiness must come after netcfg scheme registration
- Boot-time `netcfg-setup` raced `smolnetd` because `netstack/src/main.rs` called `daemon.ready()` before `Smolnetd::new()`.
- `Smolnetd::new()` constructs `NetCfgScheme::new()`, and that call is what registers `netcfg:` in the namespace.
- Fix in our tree: `nix/pkgs/system/base.nix` applies `patch-smolnetd-ready-order.py`, which moves `daemon.ready()` to after `Smolnetd::new()` succeeds.
- Manual `/bin/netcfg-setup static-auto ...` was a misleading workaround; the real failure window was only early boot, before `netcfg:` existed.

### Ion `&>` redirect doesn't work
- `#!/bin/ion\ncommand &> /var/log/file.log` — the `&>` syntax doesn't capture output
- Log file is never created
- Same issue affects `dhcpd-quiet` wrapper (also uses `&>` in Ion)

## Per-Path Proxy Deadlock — Root Cause Found

### The proxy deadlocks because the kernel blocks file: I/O from scheme-socket owners
- NOT a relibc init/exec issue — setns correctly updates ns_fd, exec passes it through auxv
- The proxy thread owns a scheme socket (file: in child namespace)
- When it does raw_openat(root_fd, ...) to forward requests to redoxfs, the kernel blocks it
- The kernel policy: any process owning a scheme socket cannot do file: I/O, even to different file: instances
- This is a blanket name-based block, not per-instance
- The proxy starts successfully, receives the first request, but deadlocks trying to forward it
- Test evidence: snix-sandbox-test boots fine but hangs after "SNIX SANDBOX BUILD TESTS" — zero test output
- Fix applied: disabled proxy in local_build.rs, using scheme-level sandbox (mkns with real file:)
- Proxy code preserved in build_proxy/ for future kernel fix

## Active Workarounds (still needed)

### Proxy deadlock theory was too broad
- I had recorded that "the kernel blocks all file: I/O from a process owning a scheme socket". That is wrong.
- `stored`/`profiled` already proved root-fd filesystem I/O works from a separate worker thread inside a scheme-owning process.
- Real deadlock shape: the scheme EVENT-LOOP thread cannot block inside nested redoxfs calls while servicing another userspace-scheme request.
- Fix direction: move real filesystem calls onto a worker thread; do not blame process-wide scheme ownership.

### Proxy scheme socket close doesn't unblock next_request() (kernel bug)
- Closing scheme socket fd from another thread does NOT unblock blocked `next_request()`.
- Workaround: event loop checks `handler.handles.is_empty()` and exits when builder exits.
- Code: `snix-redox/src/build_proxy/lifecycle.rs` ~line 206.
- Upstream fix would be in kernel/redox-scheme — not actionable from here.

### Code patterns to maintain (not bugs, just Redox differences)

- **child_ns_fd close after spawn**: mkns() fd shared by parent and child. Parent must close its copy after spawn. Do NOT close in child's pre_exec — setns() stores the raw fd. Code: `local_build.rs` ~line 401.
- **stdout flush before exit**: Redox exit handlers may not flush stdout. Always `stdout().flush()` before process exit. Code: `local_build.rs` ~line 1143.
- **sched_yield over thread::sleep**: thread::sleep uses nanosleep which routes through scheme I/O — deadlocks if initnsmgr is busy. Only matters in poll loops during sandbox builds.

## Standalone .ion File Gotchas (test script split)

### Heredoc terminators must be at column 0 in standalone files
- In the monolithic Nix `''` string, indentation stripping moved `  FLAKEEOF` → `FLAKEEOF`
- Standalone files via `builtins.readFile` + `${content}` interpolation preserve original indentation
- Lines from `${content}` paste at column 0 — no re-indentation applied by Nix
- All heredoc terminators (FLAKEEOF, LOCKEOF, NIXEOF) need column 0 in .ion files

### Ion parses ${...} inside single quotes — syntax error on / and :
- `bash -c '... ${line//$old/$new} ...'` — Ion sees `${line//` and errors on `/`
- `bash -c '... ${HASH:0:16} ...'` — same issue with `:` inside `${}`
- Fix: write bash content to a .sh file and execute it, so Ion never parses it
- `echo 'line' >> /tmp/script.sh` then `/nix/system/profile/bin/bash /tmp/script.sh`

### bootPackages must not unconditionally include userutils
- `pkgs ? userutils` is always true (mkFlatPkgs puts it in the set)
- Must also check `inSystemPackages pkgs.userutils` (profile actually uses it)
- Without this gate, `userutilsInstalled=true` everywhere → getty runs → test scripts never execute

## Namespace Gotchas

### User sessions get restricted namespaces from login's `mkns()`
- `userutils/login` calls `mkns()` with a hardcoded `DEFAULT_SCHEMES` list (26 schemes)
- New schemes (like `proc`) must be added to `/etc/login_schemes.toml` per-user override
- The config format: `[user_schemes.root]` with `schemes = ["debug", "event", ..., "proc"]`
- Debugging symptoms: `Scheme "X" not found in namespace` in initnsmgr logs, ENODEV from opens
- init process has full namespace; children inherit it; login creates RESTRICTED child namespace

### strace-redox uses obsolete syscall ABI
- Depends on `redox_syscall 0.3.4` which has `SYS_KILL=37`, `SYS_WAITPID=7`, `SYS_GETPID=20`
- Current kernel has NO handlers for these — all return ENOSYS
- Modern Redox routes kill/waitpid/getpid through proc: scheme `SYS_CALL` interface
- strace binary needs full rewrite or redox_syscall upgrade to work

## Bare Metal: GMKtec N150 (Alder Lake-N) ACPI Deadlock

### hwd.probe() deadlocks on N150 after AML init failure
- N150 firmware ACPI tables reference phantom Thunderbolt controller `_SB_.PC00.TXHC`
- `Interpreter::new_from_platform()` returns `Aml(LevelDoesNotExist(...))` — error is logged
- hwd.probe() then reads `/scheme/acpi/symbols` → acpid handles request → **deadlocks**
- The deadlock is in acpid's single-threaded event loop processing the symbols read
- acpid IS required — PCI BAR mapping needs it for USB, NVMe, network on Alder Lake-N
- Skipping acpid entirely → boots to login but USB HID doesn't work (no BAR mapping)
- Fix: override initfs scripts to start acpid + pcid directly, skip hwd entirely
- Three services: `40_hwd.service` → acpid, `40_pcid.service` → pcid, `40_pcid-spawner.service` → pcid-spawner
- pcid-spawner must `requires_weak` the new `40_pcid.service` (not just `40_hwd.service`)

### JetKVM virtual media: image must be flash drive, not CD-ROM
- `jetkvm_virtual_media mount` with `local_file` uploads via SSH cat pipe
- 1GB image upload takes ~60s over SSH to JetKVM's ARM SoC
- UEFI auto-boots from the virtual USB — no need to enter BIOS boot menu

### JetKVM "USB not connected" means host USB stack isn't running
- Not a cable issue — means xhcid/usbhubd/usbhidd chain isn't initializing
- Root cause was missing acpid (PCI BAR mapping) when we skipped hwd

### kernelSyscallDebug patch broken with empty process list
- `kernelSyscallDebugProcesses = []` generates `.contains()` (no argument)
- `kernelSyscallDebugProcesses = ["foo"]` also generates `.contains()` — the patch script has a bug
- Use strace-redox or custom diagnostic services instead for now

## Ion Shell Gotchas (keep forgetting)

### Redox builder scripts may have no `chmod` at all
- I added a guest-side rustc wrapper in `build-snix.sh` and first used bare `chmod`, then `/nix/system/profile/bin/chmod`; both failed at runtime in the self-hosting image.
- Safer pattern: copy an existing executable (`cp /nix/system/profile/bin/bash $wrapper`) and then overwrite the file contents. Redirection keeps the executable mode, so no `chmod` is needed.
- Cargo's `CARGO_TERM_PROGRESS_WHEN=always` also needs `CARGO_TERM_PROGRESS_WIDTH` in this guest environment; otherwise cargo exits early with `error: "always" progress requires a width key`.

### `$()` crashes on empty output
- `let var = $(grep ...)` → "Variable '' does not exist" when grep returns nothing.
- Use file-based or exit-code-based testing instead.

### `tail` does not exist on Redox
- Use `cat` or `head` (from extrautils) instead.

### Cargo build pipe exit codes lost
- `cargo build 2>&1 | while read` always exits 0 (pipe breaks).
- Use file redirection + `wait $PID` to get real exit code.

### Rebuild tests need mutable `configuration.nix`
- `system::switch` updates `/etc/static`, which can re-symlink `/etc/redox-system/configuration.nix` back to the store copy.
- If rebuild does not rewrite the evaluated config back as a regular file after activation, the next "no-op" rebuild re-reads stale config and undoes the prior hostname change.
- `e2e-rebuild-test` caught this immediately: second rebuild created a bogus new generation and rollback landed on the wrong hostname.
- `rebuild-artifacts-test` also taught same lesson on tool availability: after a package-only rebuild, profile-only helpers like `/nix/system/profile/bin/bash` can disappear, so late test phases must use boot-essential tools or run before package replacement.
- Inline rebuild-managed files now ride through `RebuildConfig.files`; `merge_config()` stores the literal contents in `manifest.files[*].text`, and activation writes those bytes directly. This avoids the old "can not create files from thin air" limitation for live `/etc/...` additions.
- I re-broke `self-hosting-test.nix` by inserting a column-0 `EOF` inside the Nix `''` string. That disables indentation stripping and breaks later heredoc terminators like `PKGNIX`. Use `printf`/`echo` instead of a new heredoc when editing these giant embedded scripts.
- `nix/pkgs/infrastructure/snix-source-bundle.nix`'s `fetchCargoVendor` hash changed after `snix-redox` source edits even without a Cargo.lock change. When `.#self-hosting-test` suddenly fails in `snix-redox-vendor-vendor-staging.drv`, grab the new `got:` hash from the build error and update that file before rerunning.
