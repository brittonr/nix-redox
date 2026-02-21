# Napkin — Redox OS Build System

## Corrections & Lessons

### Nix store file permissions
- Nix store strips write bits from all files
- `chmod 755` → `555`, `chmod 644` → `444`, `chmod 600` → `444`
- Tests checking file modes must use Nix-adjusted values, not the chmod arguments

### Lazy evaluation in adios modules
- Nix evaluates lazily — setting an invalid option value won't error unless something reads it
- `/hardware.graphicsDrivers` is only read by the build module when `/graphics.enable = true`
- Type validation tests for enum fields must ensure the code path that reads the field is actually exercised
- The `builtins.tryEval + deepSeq` on `system.diskImage.outPath` forces the derivation creation but doesn't force evaluation of unused option paths

### mkLibTest function signature
- All function arguments without defaults are required
- `expected` was required but some tests only used `contains`/`notContains`
- Fixed by making `expected` optional with `expected ? null`

### Mock packages for rootTree binaries
- The build module copies binaries from `systemPackages` and `base` to rootTree's `/bin/`
- `ion` is in the `ion` package, not `base` — it must be explicitly added via `systemPackages` for tests
- `base` contains daemons (init, logd, pcid, etc.), not shells or user tools

### Expect pty buffering vs file-based serial logging
- Expect's `-re ".+"` pattern with `string match` fails on VM serial output because ANSI escape codes contain `[` which Tcl interprets as character class brackets
- Switching to `string first` didn't fully resolve it — pty buffering still caused milestones to be missed
- **Solution**: Run VM with `--serial file=path` (Cloud Hypervisor) or `-serial file:path` (QEMU), then poll the log file with grep from a shell script. This completely avoids Tcl/expect complexity and works reliably
- Cloud Hypervisor boots in ~1s wall time; full test including setup takes ~3s

### Minimal profile getty fallback
- The minimal profile doesn't include `userutils` (which provides `getty` and `login`)
- init.rc used to hardcode `/bin/getty debug:` which failed on minimal
- Fixed: init.rc now conditionally uses `/startup.sh` when userutils is not in `allPackages`
- The check uses derivation reference equality: `builtins.any (p: p == uu) allPackages`
- Profiles WITH userutils still use getty for proper login

### Graphical profile disk size overflow
- 512MB disk (200MB ESP + 312MB RedoxFS) was too small for graphical profile
- Orbital + orbdata + orbterm + orbutils + audio drivers exceed ~312MB
- Fixed by adding `diskSizeMB` and `espSizeMB` options to `/boot` module
- Graphical profile now sets `diskSizeMB = 1024`
- Build module reads `inputs.boot.diskSizeMB or 512` for backward compatibility

### Test script conditionals with grep
- `if nix build ... 2>&1 | grep -v 'warning:'; then` breaks the conditional
- grep -v eats all output, causing the if to fail even on success
- Always redirect stderr to /dev/null for clean conditionals: `if nix build ... 2>/dev/null; then`

### NixBSD-inspired improvements (fdf0692, Feb 19 2026)
- Worker subagents may claim success but not persist files — always verify with `git status`/`ls`
- When changing `toplevel` semantics in default.nix, must update artifact test defaults too
  - Old: `artifact ? "toplevel"` → `system.toplevel` → rootTree
  - New: `artifact ? "rootTree"` → `system.rootTree` (toplevel is now metadata derivation)
- Composable disk image: ESP image outputs a single file (`$out`), not a directory
- `adios.lib.importModules` auto-discovers `.nix` files in modules/ — new module files are picked up automatically
- The `prefixTests` function in tests/default.nix adds a prefix — don't double-prefix test attrnames
- Korora types: `t.int` (not `t.integer`), `t.bool`, `t.string`, `t.enum "Name" [...]`, `t.struct "Name" {...}`
- Structured services: `renderService` must handle missing `enable` field with `svc.enable or true`

## What Works
- 68 module system tests across 4 layers all pass
- Mock packages build in seconds, enabling fast iteration
- Type validation catches invalid enums, missing struct fields, and wrong types
- Artifact tests verify file content (semicolon-delimited passwd, init scripts, etc.)
- Automated boot test passes in ~500ms using Cloud Hypervisor with KVM
- Boot test milestones must match actual boot phases, not just any string:
  - "initfs" matched bootloader progress download, NOT kernel/initfs execution
  - Use "Redox OS Bootloader" for bootloader, "Redox OS starting" for kernel
- 1-second polling can't distinguish boot phases; use 100ms + ms timestamps

### redoxfs-ar requires pre-allocated image file (Feb 19 2026)
- `redoxfs-ar` opens an existing file — it does NOT create one from scratch
- Must `dd if=/dev/zero of=redoxfs.img bs=1M count=$SIZE` before calling `redoxfs-ar`
- Size = diskSizeMB - espSizeMB - 4 (GPT overhead)
- Fixed in `nix/redox-system/lib/make-redoxfs-image.nix`

### Test artifact paths: rootTree uses usr/bin/ and etc/init.d/
- Build module copies package binaries to `usr/bin/`, not `bin/`
- init.d scripts with `directory = "init.d"` map to `etc/init.d` in rootTree
- `usr/lib/init.d` scripts are for rootfs-only services (e.g., orbital)
- Mock packages in `nix/tests/mock-pkgs.nix` must include ALL packages that build module references via `pkgs ? name`

### nix-darwin inspired features (a00a050, Feb 19 2026)
- Worker subagents claimed success but changes WEREN'T PERSISTED — always `git status` / `grep` to verify
- Three features added: assertions, systemChecks, version tracking
- Assertions go in the `/build` module (only place with cross-module visibility in adios)
- Must guard assertions with enable flags: `!(networkingEnabled && mode == "static")` not just `!(mode == "static")`
  because networking.enable defaults to `true` — type tests that set `mode = "static"` without interfaces will fail
- `nix eval --impure` caches aggressively; use `--no-eval-cache` or rebuild to see changes
- `assert` chains: `rootTree = assert assertionCheck; assert warningCheck; hostPkgs.runCommand ...`
- Warnings use `builtins.trace` via `lib.foldr` — they show during eval, not build
- systemChecks is a derivation that inspects rootTree at build time (separate from eval-time assertions)
- versionInfo is a plain attrset (not a derivation) — can be accessed without building
- The `valid-network-mode-static` type test needed an interface added after assertions were introduced

### New config modules (5 modules, v0.3.0, Feb 19 2026)
- Added /security, /time, /programs, /logging, /power modules
- New .nix files in modules/ MUST be `git add`ed for flakes to see them (readDir only sees tracked files)
- ALL option fields must be accessed somewhere in the build module — Nix is lazy, unread fields skip type validation
  - `hwclock` field was not accessed → `type-invalid-hwclock` test passed when it should have failed
  - Fixed by generating /etc/hwclock file that reads the field
- The build module `/build` is the only consumer — new modules add inputs there + generate files in allGeneratedFiles
- `or` defaults (e.g., `inputs.time.hwclock or "utc"`) DO still validate if the attribute exists — the type check fires on access
- When adding conditional config files, use `lib.optionalAttrs` pattern to gate on enable flags
- Duplicate attrset keys (e.g., two `etc/ion/initrc` entries) — later one silently wins; remove the old one explicitly

### redox-rebuild CLI (Feb 19 2026)
- `ls -1v "$DIR"/system-*-link` follows symlinks to directories and lists CONTENTS, not the links themselves
  - Fix: use a glob in a for loop with `[ -L "$link" ]` guard, pipe through `sort -t- -k2 -n`
- Worker subagents AGAIN claimed success but didn't persist the file — ALWAYS verify with `ls`/`cat` after delegate_task
- nix-darwin heredoc `cat <<EOF` DOES expand `$VAR` but NOT `$'\033'` syntax — use variables set with `$'...'` before the heredoc
- Color codes should be conditional on terminal: `if [ -t 2 ]; then RED=$'\033[1;31m'; else RED=""; fi`
- `nix eval .#package.version` doesn't work for an attrset inside a derivation's output — use legacyPackages path instead
- Generation dir `.redox-generations/` must be in `.gitignore` (flakes sees tracked files only)
- New Nix files MUST be `git add`ed before `nix build` (flake readDir limitation)
- `nix run .#app -- subcommand` requires `--` to separate nix args from app args

### snix-redox: Nix on Redox (Feb 19 2026) — 50 tests, 0 warnings
- snix-eval (Nix bytecode VM) cross-compiles clean to x86_64-unknown-redox — ZERO platform-specific code
- nix-compat sync features (NAR, store paths, narinfo, derivations) also compile clean
- mimalloc-sys hard dep in upstream nix-compat — only used in benchmarks, not library code
  - relibc's stdatomic.h incompatible with mimalloc's C atomics (_Atomic types)
  - Fix: local nix-compat fork with mimalloc removed from [dependencies]
- ureq v3 with rustls → ring → C compilation issues with cross-compile
  - Fix: `default-features = false` (HTTP only, no TLS) for initial prototype
  - Production: add rustls back once integrated into mkUserspace (proper CC/CFLAGS)
- Pure Rust decompression: ruzstd, lzma-rs, bzip2-rs — no C code, compiles clean
- Release binary: 76KB statically linked ELF for x86_64-unknown-redox
- Debug binary: 58MB (mostly debug symbols)
- IMPORTANT: tokio/tonic-dependent snix crates (castore, store, build, glue) are NOT portable
  - Use only: snix-eval, nix-compat (sync), snix-serde
- dirs-sys (via snix-eval → dirs) is fine — thin libc wrapper, no C code
- snix's `EvalIO` trait needs only: path_exists, open, file_type, read_dir, import_path, get_env
  - All use std::fs which maps to relibc on Redox
  - The `StdIO` impl uses `#[cfg(target_family = "unix")]` — Redox is unix family ✓

### Packaging snix-redox (bb4c172, Feb 19 2026)
- nix-compat-derive had `workspace = true` references but no workspace root in snix-redox/Cargo.toml
  - Fix: Replace `proc-macro2 = { workspace = true }` with `proc-macro2 = { version = "1" }` etc.
  - Remove dev-dependencies entirely (not needed for cross-compilation with panic=abort)
- `gitSources` in mk-userspace expects `[{ url = "git+https://..."; git = "https://..."; }]` NOT `["crate-name"]`
- In-tree source (snix-redox/) referenced as `../../snix-redox` from packages.nix (relative path works in flakes)
- delegate_task workers STILL don't persist changes — 3 more failed attempts this session. ALWAYS implement directly.
- snix cross-compiles to a 3.5MB static ELF for x86_64-unknown-redox

### System manifest & snix introspection (Feb 19 2026)
- `rename_all = "camelCase"` in serde converts `disk_size_mb` → `diskSizeMb` (lowercase m)
  but Nix attrsets use `diskSizeMB` (uppercase MB) — need explicit `#[serde(rename = "diskSizeMB")]`
- File hash inventory has circular dependency: manifest.json can't include own hash
  Solution: compute hashes at end of rootTree build, skip manifest.json itself in the walk
- The `source` attribute in allGeneratedFiles (for pre-built store files) needs mkGeneratedFiles
  to check `if file ? source then file.source else writeText ...`
- Default disk size 512MB was too small once snix (3.6MB) + manifest was added — bumped to 768MB
  The default lives in boot.nix (module options), NOT the build module's fallback
- Functional test profile MUST NOT include userutils — when present, init runs getty not /startup.sh
- Ion shell redirect: `>` for stdout, `^>` for stderr — NOT `1>` / `2>` (bash syntax)
  The `1` in `1>/tmp/file` gets passed as an argument to the command!
- `grep -c` returns "0" AND exits 1 on no match; `$(grep -c ... || echo 0)` produces "0\n0"
  Fix: `VAR=$(grep -c ...) || VAR=0` (assignment-then-fallback, not subshell-with-fallback)

### Wiring virtualisation module (bb4c172, Feb 19 2026)
- Build module returns vmConfig attrset; redoxSystem factory exposes it; system.nix passes to runner factories
- Runner factories accept `vmConfig ? {}` with `or` defaults for backward compatibility
- Cloud profile correctly flows `tapNetworking = true` through the entire chain
- QEMU runners: replace hardcoded `-m 2048 -smp 4` with `${defaultMemory}` `${defaultCpus}` from vmConfig

### Functional test suite design (Feb 19 2026)
- Split VM tests from static checks: config existence/format → artifact tests (no VM, seconds), runtime behavior → VM tests
- Only things needing a VM: shell execution, filesystem I/O, binary execution, device files
- Static checks (passwd, hostname, security policy, symlinks, binaries) → `artifact-rootTree-dev-*` tests
- In-guest test approach: modify startupScriptText to run tests, avoids pty/expect entirely
- Tests output `FUNC_TEST:name:PASS/FAIL` to serial; host script polls the file (same pattern as boot test)
- Ion shell (not bash) runs the test script — `let var = val`, `if test ... end`, `exists -f`
- Startup script gets `#!/bin/sh` prepended by build module (sh→ion symlink on Redox)
- `specialSymlinks` (e.g., `bin/sh → /bin/ion`) are DANGLING in Nix store — use `[ -L ]` not `[ -e ]` in artifact tests
- New profile `functional-test.nix` extends development with test runner
- `mkFunctionalTest` factory in infrastructure alongside `mkBootTest`

### Generation system (Feb 19 2026)
- `#[serde(default)]` on struct fields with `impl Default` allows backward-compatible manifest evolution
  - Old manifests without `generation` field deserialize cleanly using `GenerationInfo::default()`
- `tempfile` v3.25.0 pulls rustix v1.1.3 which is broken on nightly 1.92.0 — pin to tempfile v3.14.0
- Generation buildHash is computed from the sorted file inventory JSON (content-addressable)
  - This avoids any Nix store path identity leaking into the hash
- Generations dir in rootTree MUST be excluded from the file inventory walk to avoid self-reference
- `days_to_date` uses Howard Hinnant's civil days algorithm — pure arithmetic, no deps
- rollback creates a NEW generation (forward-moving counter), not an in-place revert
  - This preserves the audit trail: gen 1 → gen 2 → gen 3 (rollback to 1)
- Functional test for `switch`: must set up BOTH a current manifest file AND a new one
  - First `cp` the real manifest, then call switch with `--manifest /tmp/copy.json`

### snix eval end-to-end tests (Feb 20 2026)
- Added 8 `snix eval` tests to functional-test.nix profile (total ~46 tests now)
- Tests exercise the snix bytecode VM inside a running Redox VM: arithmetic, let bindings, strings, builtins, functions, conditionals, attrsets, typeOf
- Uses `--expr` for simple expressions (e.g., `"1 + 1"`), `--file` for complex ones (avoids Ion quoting issues)
- Ion shell quoting: single quotes `'...'` prevent all expansion (safe for Nix expressions with `{}[]()`)
- Inside Nix `''..''` strings, single quotes are literal — no escaping needed
- Ion `$()` command substitution strips trailing newlines (same as bash) — exact value comparison works for integers
- For string outputs (e.g., `"hello world"` with quotes), use `grep -q` pattern matching instead of exact comparison
- Ion redirect syntax: `>` for stdout, `^>` for stderr (NOT `2>`)
- Cleanup `rm` at end not critical — VM is destroyed after test — but included for tidiness

### snix store layer — nixbase32 test path pitfall (Feb 20 2026)
- Nix store paths use nixbase32 alphabet: `0123456789abcdfghijklmnpqrsvwxyz` (32 chars)
- Letters NOT in nixbase32: 'e', 'o', 't', 'u' — these are MISSING from the alphabet
- Test paths like `/nix/store/ooooo...-orphan-1.0` FAIL with "Hash encoding is invalid"
- Must use only valid nixbase32 characters in synthetic test store paths
- All 32 hash characters must come from the valid set — one bad char = parse failure
- The PathInfo database keys by the nixbase32 hash: same hash prefix → same JSON file
  - Tests registering multiple paths MUST use paths with different hash components

### snix store layer v0.3.0 (Feb 20 2026)
- Added `pathinfo.rs`: JSON-based per-path metadata DB at `/nix/var/snix/pathinfo/{hash}.json`
- Expanded `store.rs`: closure computation (BFS), GC roots, mark-and-sweep garbage collection
- Expanded `cache.rs`: recursive closure fetching (`snix fetch --recursive`)
- New CLI: `snix store {list,info,closure,gc,add-root,remove-root,roots,verify}`
- PathInfoDb uses filesystem as database — each store path gets its own JSON file
- GC roots are symlinks in `/nix/var/snix/gcroots/` pointing to store paths
- Closure = BFS traversal over PathInfo references (handles diamonds, self-refs)
- GC = compute live set from all roots' closures, delete everything else
- Cross-compiles to 3.7MB static ELF for x86_64-unknown-redox (no new C deps)
- 113 host unit tests + 53 VM functional tests (8 new store tests), all pass

### snix-eval "Invalid opcode fault" on Redox — root cause (Feb 20 2026)
- ALL `snix eval` commands crashed with "Invalid opcode fault" at RIP 0x632032 (ud2 instruction)
- Non-eval commands (system info/verify/generations/switch) worked fine
- Root cause chain:
  1. `snix-eval` build.rs sets `SNIX_CURRENT_SYSTEM` = Cargo `TARGET` env → `x86_64-unknown-redox`
  2. `builtins/mod.rs` reads it at compile time: `const CURRENT_PLATFORM = env!("SNIX_CURRENT_SYSTEM")`
  3. `pure_builtins()` eagerly calls `llvm_triple_to_nix_double("x86_64-unknown-redox")`
  4. `systems.rs::is_second_coordinate()` only matches `linux|darwin|netbsd|openbsd|freebsd` — NOT `redox`
  5. Falls through to `panic!("unrecognized triple x86_64-unknown-redox")`
  6. With `panic = "abort"`, panic handler emits `ud2` instruction → kernel kills process
- Fix: patch vendored snix-eval's `is_second_coordinate` to include `"redox"` in the match
- The `abort` function at 0x631f80 IS the panic handler — `ud2` is the intentional termination mechanism
- Disassembly key: `testq %rax, %rax / je 0x632032` jumps to `ud2` when log level is 0 (no logging configured)
- Must regenerate .cargo-checksum.json after patching vendored crates

### Binary cache bridge — snix install (Feb 20 2026)
- NAR format serialization in Python: strings are 8-byte LE length + content + padding to 8-byte alignment
- Symlinks must be handled BEFORE directory check (`os.path.islink` before `os.path.isdir`)
- zstd -19 gives ~35% ratio on mock packages; real binaries will be larger
- `builtins.unsafeDiscardStringContext` breaks Nix dependency tracking — use `"${drv}"` interpolation instead
- `nar::extract` requires `Read + Send` trait bound — `Box<dyn Read>` must be `Box<dyn Read + Send>`
- `t.attrsOf t.derivation` works in Korora for typed package maps
- Binary cache at `/nix/cache/` in rootTree; profile at `/nix/var/snix/profiles/default/`
- narinfo filename = first 32 chars of store path basename (nixbase32 hash)
- NarHash uses hex encoding in narinfo (`sha256:abcdef...`) — nix-compat parser handles both hex and nix32
- `lib.optionalString` for conditional bash in Nix derivations; `lib.optionalAttrs` for conditional attrsets
- Include `/nix/store` and `/nix/var/snix/` dirs in rootTree so snix doesn't need to create them at runtime
- Profile bin added to PATH via /etc/profile when binary cache is enabled
- 119 host unit tests + 76 artifact tests + 10 new functional tests for install pipeline
- CRITICAL: nix-compat NarInfo parser uses nixbase32 for FileHash (not hex!)
  - NarHash accepts BOTH hex (64 chars) and nixbase32 (52 chars)
  - FileHash ONLY accepts nixbase32 (calls `nixbase32::decode_fixed::<32>`)
  - Error message: "unable to decode FileHash: invalid length at 52"
  - Solution: nixbase32_encode() in Python — processes bytes MSB-first, 5 bits per char
  - Verified: Python nixbase32 matches `nix-hash --to-base32` exactly

### base-src init rework (fc162ac, Feb 18 2026)
- base-src fc162ac reworked init: numbered init.d/ scripts replace init.rc
- SchemeDaemon API: nulld/zerod/randd/logd/ramfs use `scheme <name> <cmd>` not `notify`
- pcid-spawner now uses `--initfs` flag (shared config locator crate)
- pcid config moved from etc/pcid/ to etc/pcid.d/
- ipcd, ptyd, USB daemons are rootfs services — do NOT put in initfs init scripts
- acpid is spawned by pcid-spawner — do NOT notify it directly (causes "File exists" crash)
- Boot test bisecting caught the regression — exactly what it was built for

### Mock package pname mismatch (Feb 20 2026)
- Mock packages in nix/tests/mock-pkgs.nix use short names (`ion`, `base`, `snix`)
- Real packages use prefixed pnames (`ion-shell`, `redox-base`, `snix-redox`)
- Build module's `isBootEssential` uses `pkg.pname or (builtins.parseDrvName pkg.name).name`
- Mock packages need explicit `pname` attribute via `// { inherit pname; }` to match
- `mkMockPackageWithBins` now accepts optional `pname` parameter
- Without this fix, artifact tests for boot/managed classification silently misclassify everything

### snix unit tests require --target x86_64-unknown-linux-gnu (Feb 20 2026)
- `snix-redox` is a cross-compiled crate targeting x86_64-unknown-redox
- `cargo test` without `--target` tries to link with relibc (which isn't available on host)
- Must use `cargo test --target x86_64-unknown-linux-gnu` to run tests on the host
- Alternatively set `CARGO_BUILD_TARGET=""` to avoid inheriting the cross-target
- All #[cfg(test)] modules compile fine for linux — no redox-specific APIs used in tests

### Generation counting in Ion shell (Feb 20 2026)
- `grep -c '^[[:space:]]*[0-9]'` doesn't work reliably in Redox grep
- `wc -l` is more reliable for counting output lines
- `snix system generations` outputs: 5 header lines + N gen entries + 2 footer lines
- So `wc -l > 10` means at least 4 generation entries (header=5, footer=2, data≥4)

### Artifact test coverage (58 total, Feb 20 2026)
- 16 new store/profile/generation artifact tests added
- Key invariants tested: boot-essential stays in /bin/, managed goes to profile, symlinks target /nix/store/
- `rootTree-boot-vs-profile-separation` is the CRITICAL test — catches classification bugs
- `rootTree-profile-symlinks-to-store` verifies symlinks actually point to valid store paths
- `rootTree-path-precedence` verifies /nix/system/profile/bin comes before /bin in PATH

### GC roots + generation integration (Feb 20 2026)
- `update_system_gc_roots()` called from both `switch()` and `rollback()`
- Creates `system-{name}` GC roots for each package with non-empty store_path
- Old `system-*` roots cleared first (atomic swap of the protection set)
- Errors are warnings via `if let Err(e)` — switch/rollback never fails due to GC root issues
- Unit tests verify switch/rollback succeed even when /nix/var/snix/gcroots/ doesn't exist
- VM test `gen-gc-safe` verifies system-* roots exist after switch
- VM test `gen-gc-dry-run` verifies `snix store gc --dry-run` doesn't crash

### Channel system design (Feb 20 2026)
- Channels stored at `/nix/var/snix/channels/{name}/` with `url`, `manifest.json`, `last-fetched`
- `snix channel update` fetches manifest.json from URL via ureq (already a dependency)
- `snix system switch --channel stable` resolves to channel's cached manifest path
- `channel::get_manifest_path()` returns PathBuf for the cached manifest
- `system::current_timestamp_pub()` is the public accessor (private `current_timestamp()` stays private)
- main.rs Switch command now takes `path: Option<String>` + `channel: Option<String>`
- Type annotation `Result<String, Box<dyn std::error::Error>>` needed for the match arm (inference fails)

### Profile subcommand expansion (Feb 20 2026)
- `snix profile install/remove/show` now wired through ProfileCommand enum
- These delegate to existing `install::install()`, `install::remove()`, `install::show()`
- Top-level `snix install/remove/show` still works too (backward compat)
- ProfileCommand::Install/Remove/Show mirror the top-level commands exactly

### Atomic activation system (Feb 20 2026)
- `activate.rs` implements NixOS-style `switch-to-configuration` for Redox
- Atomic profile swap: build in staging dir (`/nix/system/.profile-staging/bin/`), then `rename()` to `/nix/system/profile/bin`
  - Falls back to non-atomic clear+rebuild if `rename()` fails (e.g., cross-mount)
  - Cleanup leftover staging/old dirs from previous failed activations
- Activation plan computes full diff: packages, config files, services, users
  - Uses `BTreeMap`/`BTreeSet` for deterministic ordering in diffs
  - Config file changes detected by BLAKE3 hash comparison from manifest
- `switch()` signature changed: added `dry_run: bool` parameter — ALL test callsites need updating
- `update_system_gc_roots_pub()` added as public accessor for `activate` module to call
- `activate_cmd()` is the standalone command handler; `activate()` is the core function called by both `switch()` and `rollback()`
- Reboot detection: checks initfs driver changes, storage driver changes, disk layout changes
  - Redox has no service hot-restart — service changes always recommend reboot
- 33 new unit tests in `activate::tests` covering plan computation, profile population, config diff, user diff, cleanup helpers
- 3 new VM functional tests: `activate-dry-run`, `switch-dry-run-no-modify`, `activate-no-changes`
- CRITICAL BUG: initial activate() only rebuilt profile when `plan.profile_needs_rebuild` was true
  - Test: delete rg symlink, switch to SAME manifest → packages identical → plan says "no changes" → skip rebuild → rg stays deleted
  - Fix: activation must be IDEMPOTENT — always rebuild profile and GC roots regardless of plan
  - The plan is for DISPLAY (dry-run); execution must always converge to declared state
  - This is exactly how NixOS switch-to-configuration works — always re-activate, don't skip
  - Verified: reverting to old code = 3 failures gone; old code always rebuilt unconditionally
  - After fix: 94/94 VM tests pass, 0 failures
- Cross-compiled binary grew from 3.7MB to 3.9MB (activate module adds ~200KB)

### QEMU test runner: -vga none required (Feb 20 2026)
- QEMU with `-display none` still emulates a VGA card by default
- The VGA card provides a GOP device to UEFI firmware
- The Redox bootloader detects GOP → shows resolution selection screen → waits for keyboard
- Cloud Hypervisor with `--console off` provides no display device → bootloader skips picker
- Fix: add `-vga none` to all headless QEMU invocations (boot-test, functional-test)
- Boot test: stuck forever → 2.2s with fix
- Note: the graphical QEMU runner DOES need VGA (uses `-vga std -display gtk` + expect script)

### Redox grep doesn't support \| alternation (Feb 20 2026)
- `grep -qi 'pattern1\|pattern2'` silently matches nothing on Redox
- Must use separate `grep` calls with if/else fallthrough
- Same applies to extended regex (`grep -E`) — not reliably available
- Pattern: check each alternative in nested if/else blocks

### System upgrade pipeline — local channel testing (Feb 20 2026)
- `snix system upgrade` works with local channels (no network needed)
- Channel = directory with `url`, `manifest.json`, optionally `cache-url` and `packages.json`
- For VM tests: create channel dir at runtime, use `snix eval` to transform current manifest
  - `snix eval --raw --file /tmp/transform.nix` reads manifest JSON, overrides fields, outputs new JSON
  - This is dogfooding: Nix bytecode VM running on Redox transforms its own system config
  - Ion single quotes `'...'` prevent all expansion — safe for Nix expressions with `{}//()`
- `sed` is NOT available on Redox (not in uutils) — cannot use it for text transformation
- Channel `update()` gracefully handles fetch failure + falls back to cached manifest
- `fetch_upgrade_packages()` tries 3 strategies: channel-local cache → /nix/cache/ → remote URL
- Second upgrade with same manifest = "up to date" (detected by build hash comparison)
- 102 VM functional tests, 178 host unit tests — all pass

### Declarative rebuild — snix system rebuild (Feb 20 2026)
- `snix system rebuild` evaluates `/etc/redox-system/configuration.nix` via snix-eval → JSON → merge → switch
- configuration.nix is a simple Nix attrset — no functions, no imports, no module system
- `builtins.toJSON (import /path)` is the full Nix expression; snix-eval handles the rest
- snix-eval's Display representation of a Nix string is quoted+escaped: strip outer `"` and unescape `\"`
- JSON config fallback: if path ends with `.json`, skip snix-eval and parse directly (testability)
- Boot-essential packages (ion, base, uutils, snix) always preserved during package merge
- All RebuildConfig fields are `Option<T>` — only present fields override the current manifest
- Users field replaces entirely (no merge); groups auto-generated from users
- delegate_task workers STILL don't persist files — 4th or 5th time this session. ALWAYS implement directly.
- The `User` struct in system.rs needed `PartialEq` derive for comparison in rebuild.rs
- The build module generates configuration.nix with current system values interpolated
- 198 host unit tests + 110 VM functional tests + 161 nix checks — all pass
- Cross-compiled binary: 4.0MB (+100KB for rebuild module)

### virtio-fsd driver for Redox (Feb 20-21 2026)
- virtio-fs = FUSE protocol over virtqueues (virtio device type 26, PCI ID 0x1AF4:0x105A)
- Cloud Hypervisor `--fs tag=shared,socket=/tmp/virtiofsd.sock` presents device to guest
- Host side: virtiofsd (Rust, available in nixpkgs) serves a directory via FUSE protocol
- Driver structure mirrors virtio-blkd: PCI probe via virtio-core → virtqueues → scheme
- Differences from virtio-blkd:
  - TWO queues: hiprio (queue 0, for FORGET) + request (queue 1, for everything else)
  - Messages are FUSE structs (FuseInHeader + args → FuseOutHeader + response), not block I/O
  - Config space: 36-byte UTF-8 tag + u32 num_request_queues (not capacity/block_size)
  - Exposes SchemeSync (filesystem API), not DiskScheme (block device API)
- Minimal FUSE ops for read-only: INIT, LOOKUP, GETATTR, OPEN, READ, READDIR, RELEASE, OPENDIR, RELEASEDIR, STATFS
- Memory: `shared=on` required in Cloud Hypervisor `--memory` for virtio-fs DAX
- virtiofsd flags: `--sandbox=none` (no seccomp in non-Linux guest), `--cache=auto`
- PCI registry entry added to build module; StorageDriver enum extended; cloud-hypervisor profile includes it
- Runner: `run-redox-cloud-hypervisor-shared` starts virtiofsd + VM with `--fs`
- Source: nix/pkgs/system/virtio-fsd/ (1384 lines across 5 files)
- Injected into base workspace via patchPhase (copies source, adds to Cargo.toml members)
- This is the CHANNEL for the build bridge: host writes to shared dir, guest reads via /scheme/shared/

### virtio-fsd compilation fixes (Feb 21 2026)
- **Heredoc indentation bug**: VIRTIOFS_TOML heredoc content at 6-space indent pulled down
  the Nix `''` string's minimum indentation, leaving the Python `EOF` terminator with 6
  leading spaces — bash couldn't find it. Fix: use `pkgs.writeText` for Cargo.toml content.
- **Redox Stat struct**: `st_atime`, `st_mtime`, `st_ctime` are plain `u64` (not `TimeSpec`).
  Separate `st_atime_nsec`, `st_mtime_nsec`, `st_ctime_nsec` fields are `u32`.
- **DirentBuf.entry()**: Takes `DirEntry<'_>` struct (with `inode`, `next_opaque_id`, `name`,
  `kind` fields), not 4 separate arguments. Import as `RedoxDirEntry` to avoid name collision.
- **daemon.ready()** returns `()` (no `unwrap`). `daemon.ready_sync_scheme()` exists in source
  but Rust couldn't resolve it (possibly edition 2024 visibility issue). Fix: use separate
  `register_sync_scheme()` + `daemon.ready()` calls.
- **handle_sync()** is on `CallRequest` (from `RequestKind::Call(r)`), NOT on `Request`.
- **on_close()** is a trait default method on `SchemeSync` — must import trait with
  `use redox_scheme::scheme::SchemeSync;` at call site.
- **Vendor hash changes**: Modifying the Cargo.toml content changes the `fetchCargoVendor` hash.
  Must update the hash when Cargo.toml content changes.

### virtio-fsd disk image wiring (Feb 21 2026)
- The `run-redox-shared` runner was using the DEFAULT profile disk image, but `virtio-fsd`
  was only in the cloud-hypervisor profile's `storageDrivers`. No driver binary in the initfs!
- Fix: created `sharedFsSystem` in system.nix that extends development profile with `virtio-fsd`
- The shared runner now uses this dedicated system configuration
- Default hardware.storageDrivers = ["ahcid" "nvmed" "virtio-blkd"] — missing virtio-fsd
- Cloud profile adds it, but cloud profile has static networking that HANGS without `--net`

### virtio-fsd VM verification (Feb 21 2026) — FULLY WORKING
- Boot completes in ~1s with KVM
- Driver detects PCI device 0x105A, probes virtio device, reads tag "shared"
- FUSE_INIT handshake with host virtiofsd succeeds
- Scheme `/scheme/shared` registered in Redox namespace
- Guest can access host files via `/scheme/shared/path`
- The "non-power-of-two zeroed_phys_contiguous allocation" kernel warnings are from
  virtqueue DMA buffer allocation — harmless, the kernel rounds up automatically
- `eprintln!` is critical for debugging drivers — `common::setup_logging` goes through
  the `log:` scheme which isn't visible on serial early in boot
- Cloud Hypervisor `--serial file=path` + grep polling is the reliable test pattern

### Build bridge — push-to-redox (Feb 21 2026)
- `push-to-redox` host-side tool: build packages → serialize to binary cache → write to shared dir
- Reuses `build-binary-cache.py` (Python NAR serializer) for cache generation
- Incremental merge: new packages added to existing `packages.json`, narinfo/NAR files copied alongside
- Store path version parsing: `rsplit("-", 1)` extracts last `-`-separated component as version
  - "ripgrep-unstable" → version "unstable" (not "unknown")
  - "fd-10.2.0" → version "10.2.0"
- `SNIX_CACHE_PATH` env var added to snix (clap `env` attribute) — requires `features = ["env"]`
  - Without this feature, `#[arg(env = "...")]` produces `no method named 'env' found for struct 'Arg'`
- Guest workflow: `export SNIX_CACHE_PATH=/scheme/shared/cache` then `snix install <name>`
- Relative path from `nix/pkgs/infrastructure/` to `nix/lib/` is `../../lib/` NOT `../../../lib/`
  - Three `../` goes to repo root, but `nix/lib/` is one level down from there
- `nix copy --to file://` is NOT used — it includes host dependency closures
  - Python NAR serializer creates isolated per-package cache entries (no deps)
- `build-bridge.nix` (host-side daemon) already existed — watches for request JSON files
  - It's the "full rebuild" workflow; push-to-redox is the "push individual packages" workflow
- 198 host unit tests pass; snix cross-compiles to 4.0MB (unchanged)

### Build bridge — virtio-fs FUSE_READ fix (Feb 21 2026)
- **Root cause**: virtiofsd uses the response descriptor SIZE (not FuseReadIn.size) to determine
  how many bytes to `preadv2()` from the host file. With a fixed 1MB response buffer, virtiofsd
  would try to read 1MB even when only 8KB was requested.
- **Solution**: Size the response DMA buffer to `sizeof(FuseOutHeader) + read_size` for FUSE_READ
  and FUSE_READDIR. Use a small 4KB buffer for all metadata operations (LOOKUP, GETATTR, OPEN, etc.)
- **DMA kernel panic**: Rapid DMA allocation/deallocation caused `expected frame to be free` kernel
  panic in `deallocate_p2frame`. Workaround: `core::mem::forget()` the DMA buffers after use.
  This leaks ~12KB per FUSE request but avoids the kernel bug. Long-term fix: pre-allocate and
  reuse DMA buffers in the FuseSession.
- **Flat cache layout**: NAR files placed in cache root (not `nar/` subdirectory). The narinfo
  `URL:` field is rewritten from `nar/hash.nar.zst` to `hash.nar.zst` during merge. This avoids
  subdirectory traversal overhead and simplifies the cache structure.
- **Cache file permissions**: `build-binary-cache.py` creates files with umask 0077 → 600 perms.
  `push-to-redox` merge step chmod's all files to 644 and dirs to 755 for virtiofsd access.
- **Live push detection**: Guest polls with `snix search` (reads packages.json via FUSE) in a loop.
  Need 200 iterations to give the host 4-5 seconds to complete the push. `cat /dev/null` is NOT
  a real delay — use actual I/O operations (file reads) to introduce meaningful poll intervals.
- **virtiofsd flags**:
  - `--cache=never` required for live push detection (otherwise dir entries are cached)
  - `--sandbox=none` needed (no file handle support warning, falls back to inode-based access)
  - `FOPEN_KEEP_CACHE (0x2)` in open response is normal and benign
- **strace debugging**: `strace -f -e trace=preadv2,openat,read` on virtiofsd was key to finding
  the buffer size issue. Showed `iov_len=1052656` (full buffer) instead of `iov_len=8192` (requested)
- **Redox flag translation**: Redox open flags (O_RDONLY=0x10000, O_ACCMODE=0x30000) must be
  translated to Linux FUSE flags (O_RDONLY=0) in `redox_to_fuse_flags()` before FUSE_OPEN
- **All 30 bridge tests pass**: filesystem access, snix search, install, remove, live push, reinstall
