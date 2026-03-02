# Napkin — Redox OS Build System

## Corrections & Lessons

### Bridge rebuild end-to-end (Mar 2 2026)
- **bridge-eval.nix `//` replaces entire module path**: adios `extend` uses `//` at the module
  path level. Override `{ "/environment" = { systemPackages = [rg]; }; }` REPLACES the profile's
  entire `/environment`, losing shellAliases, existing packages, etc. Fix: resolve the profile's
  module definitions first, merge with `existingEnv // { systemPackages = combined; }`.
- **serde `None` → JSON `null`, not absent**: `{ "packages": null }` in Nix: `config ? packages`
  returns `true` even though value is `null`. Must check `config ? field && config.field != null`.
  Added `hasNonNull` helper in bridge-eval.nix.
- **Unicode in Nix errors breaks Python**: Nix error output contains `…` (U+2026). Interpolating
  `$error_msg` into Python source → SyntaxError. Fix: write error to temp file, read in Python.
- **std::thread::sleep DOES NOT WORK on Redox**: `nanosleep()` in relibc hangs forever.
  `Instant::now()` may not advance. Must use FUSE I/O operations as delay source.
- **FUSE reads are cached, writes are not**: `fs::read_to_string` on shared filesystem returns
  in ~0.3ms (cached). `fs::write` forces host round-trip (~0.3ms each but adds up). 3000
  write+read cycles ≈ 1 second wall-clock delay.
- **Bridge test needs large disk**: 25 packages = 277MB NAR. Default 768MB disk fills up
  after 14 installs. Bridge rebuild test profile uses `diskSizeMB = 1536`.
- **Test profiles MUST NOT include userutils**: init runs getty instead of /startup.sh
  when userutils is present (documented in napkin but re-learned).

### Toolchain ships pre-compiled rlibs for x86_64-unknown-redox (Feb 28 2026)
- Rust nightly-2025-10-03 ships 26 pre-compiled rlibs for x86_64-unknown-redox
- `-Z build-std` was recompiling core/alloc/std/panic_abort in EVERY package (~60-90s each × 20 pkgs)
- Fix: just REMOVE `-Z build-std` — the toolchain's rlibs work out of the box
- `--allow-multiple-definition` still needed (relibc bundles core/alloc, conflicts with sysroot rlibs)
- Packages no longer need sysroot vendor merged into their vendor directory
- Kernel/bootloader STILL need `-Z build-std` (different target triples: no_std and UEFI)
- First attempted custom prebuilt-sysroot via dummy project + `-Z build-std` → extract rlibs
  - FAILED: Cargo `-Z build-std` rlibs have different metadata hashes than sysroot rlibs
  - rustc found BOTH sets (toolchain's + ours) → E0464 "multiple candidates for core"
  - Even after removing toolchain rlibs, E0425 "cannot find Some" = wrong rlib metadata
- The simplest solution was the right one: don't fight the toolchain, just use its rlibs
- delegate_task workers STILL don't persist file changes — 6th+ time this session. ALWAYS do directly.

### packages.nix standaloneCommon pattern (Feb 28 2026)
- Standalone package imports in packages.nix had 10+ repeated `inherit` lines each
- Fixed: `standaloneCommon` attrset with all common args, then `// { specific-args }` per package
- Standalone files that receive extra args need `...` in their function params
- Some files (orbital, orbterm, orbutils) already had `...` — sed adding duplicate caused syntax error

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

### LLVM 21.1.2 cross-compilation for Redox (Mar 1 2026)
- libc++ needs localization, filesystem, and random_device enabled for LLVM
- relibc is MISSING 18 locale-aware `_l` functions (iswspace_l, strtof_l, etc.)
  → stub them in libc++ build as C++ wrappers that call the non-_l versions (C-only locale)
  → must declare in force-included compat header too
- `_LIBCPP_PROVIDES_DEFAULT_RUNE_TABLE` must be defined for libc++ on Redox
  (not Bionic, not musl, not glibc — falls through to `#error` without it)
- relibc's `mbstate_t` is an empty struct `{}` — `{0}` initialization is invalid in C++
  → sed -i to replace `= {0}` with `= {}` in locale.cpp
- `__cxa_thread_atexit` missing from libc++abi — add stub in wchar_stubs_redox.cpp
- POSIX `*at` functions (openat, unlinkat, utimensat) not in relibc headers
  → stub in libc++: openat→open, unlinkat→unlink, utimensat→noop
- cmake `check_include_file` fails for ALL relibc headers because clang doesn't add
  sysroot includes for unknown targets (x86_64-unknown-redox). Must force cmake cache:
  `-DHAVE_SYSEXITS_H=1 -DHAVE_PTHREAD_H=1 -DHAVE_UNISTD_H=1 ...`
- `-DUNIX=1` in cmake → `LLVM_ON_UNIX=1` → `ExitCodes.h #error` if HAVE_SYSEXITS_H=0
- C files need `-nostdlibinc -isystem $sysroot/include` (same as CXX), not just --sysroot
- LLD MachO/COFF backends disabled (need macOS/Windows headers) — only ELF+Wasm
  Must rewrite lld/tools/lld/CMakeLists.txt AND lld/include/lld/Common/Driver.h LLD_ALL_DRIVERS
- `__register_frame`/`__deregister_frame` needed by LLVM ORC JIT — add to stub-libs.nix
- Final: clang-21 = 91MB, lld = 57MB, llvm-ar = 11MB — all static ELF for Redox

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

### nextest 0 tests fix (Feb 28 2026)
- Root crate has `test = false` on its only binary (cross-only for x86_64-unknown-redox)
- `cargo nextest run` finds 0 tests → exits code 4 (NO_TESTS_RUN)
- nextest has NO config file key for `no-tests` — only CLI flag `--no-tests pass` or env var `NEXTEST_NO_TESTS=pass`
- `.cargo/config.toml` `[env]` does NOT pass env vars to nextest (it's a cargo subcommand, not a build target)
- `.env` file is NOT read by nextest either
- Fix: `export NEXTEST_NO_TESTS=pass` in `.envrc` (direnv) + `NEXTEST_NO_TESTS = "pass"` in devshells.nix rustEnv
- Must `inherit (rustEnv) ... NEXTEST_NO_TESTS;` in EACH shell definition that inherits from rustEnv
- After editing `.envrc`, `direnv allow` is needed for changes to take effect
- `.config/nextest.toml` kept for documentation but has no functional effect on this issue

### virtio-fsd DMA buffer reuse (Feb 28 2026)
- `Buffer::new_sized(dma, len)` exists in virtio-core — creates descriptor with custom length
  backed by a larger DMA buffer. This is the key to exact-size descriptors without per-request alloc.
- Two DMA buffers allocated once at init (no ManuallyDrop — see root cause fix below):
  - req_buf: header + FuseWriteIn + MAX_IO_SIZE rounded to p2 pages (~2MB)
  - resp_buf: header + MAX_IO_SIZE rounded to p2 pages (~2MB)
- Per-operation descriptor sizes via Buffer::new_sized:
  - Meta ops: req=actual_len, resp=4KB
  - READ/READDIR: req=actual_len, resp=header+data_size (exact, no over-read)
  - WRITE: req=header+args+data_len, resp=4KB
- Session methods changed from &self to &mut self (writes into shared DMA buffers)
- scheme.rs: resolve_path changed from &self to &mut self (calls session methods)
- FUSE_INIT uses the same pre-allocated buffers (no separate init path needed)
- FuseTransportError::RequestTooLarge added for buffer overflow protection

### virtio-fsd DMA kernel bug — root cause found & fixed (Feb 28 2026)
- **Root cause**: kernel's `zeroed_phys_contiguous` allocates 2^order pages via `allocate_p2frame(order)`
  but only initializes `span.count` pages with `RC_USED_NOT_FREE` refcount. When span.count is NOT
  a power of two (e.g., 257 pages → 512 allocated), the excess pages (257-511) have zeroed PageInfo.
- **Crash mechanism**: on munmap, `handle_free_action` frees frames 0-256 one by one. When frame 256
  is freed, the buddy allocator checks sibling frame 257. Frame 257's refcount=0 (no RC_USED_NOT_FREE bit)
  so `as_free()` returns `Some` — it looks free but ISN'T on any freelist. The merge logic follows
  stale prev/next pointers (both zero). `P2Frame(0).frame()=None` → enters the `else` branch →
  `freelist.for_orders[0] = None` → WIPES the entire order-0 freelist. This cascades through all orders.
- **Debug kernel**: panics at `debug_assert_eq!(freelist.for_orders[0], Some(sibling))` in the merge loop
- **Release kernel**: silent freelist corruption → memory leak → eventual OOM or later panics
- **Our trigger**: DMA buffers of `header(40) + FuseWriteIn(40) + MAX_IO_SIZE(1048576) = 1048656 bytes`
  → ceil(1048656/4096) = 257 pages — NOT a power of two!
- **Fix**: `round_to_p2_pages()` rounds DMA allocation sizes to next power-of-two page count.
  With 512 pages requested, `span.count == 2^order` → ALL allocated pages get proper refcount →
  buddy allocator deallocation works correctly → ManuallyDrop removed.
- **Memory**: 4 MiB total (was ~2 MiB leaked via ManuallyDrop). Now properly freeable on drop.
- **Upstream kernel fix needed**: `zeroed_phys_contiguous` should initialize ALL 2^order pages,
  and `handle_free_action` should use `deallocate_p2frame(base, order)` (per its own FIXME comment)
  instead of freeing pages one by one.

### End-to-end networking via QEMU SLiRP (Feb 28 2026)
- Full network stack works: e1000d → smolnetd → DHCP → DNS → ping → TCP
- QEMU SLiRP (user-mode networking) works perfectly — no root/TAP needed
- `-netdev user,id=net0 -device e1000,netdev=net0` is the QEMU incantation
- Guest gets 10.0.2.15/24 via DHCP, gateway 10.0.2.2, DNS 10.0.2.3
- **netcfg-setup bug**: `addr/list` returns "Not configured" before DHCP completes
  - Old code: `!content.is_empty()` → treated "Not configured" as a valid IP
  - Fix: check `content.contains('.')` to require a real IP address
- **No `sleep` binary on Redox** — not in uutils, extrautils, or any package
  - Busy-wait delay: read `/scheme/sys/uname` for real scheme I/O latency (~5ms)
  - 3000 iterations × 5ms = ~15s effective timeout
- **Ion shell `echo $var | grep` FAILS SILENTLY** — the pipe to grep doesn't work
  - Always use Ion-native string comparison: `test $var = "value"`
  - Or `not test $var = ""` for non-empty checks
  - This wasted 3 iterations of build+test debugging
- `extrautils` provides `grep`, `less`, `tar` — NOT in `uutils`
- `uutils` only has: cat, cp, df, du, echo, head, ls, mkdir, mv, pwd, rm, sort, touch, uniq, wc
- Network test completes in 2.3s (QEMU+KVM), all 9 tests pass
- procmgr "Cancellation for unknown id" warnings are harmless (from pipe cleanup)
- `ifconfig eth0` output: MAC shows 00:00:00:00:00:00 (known smolnetd issue, real MAC at /scheme/netcfg)
- DHCP takes ~75 polls (roughly 3-5 seconds) to complete after boot

### Pre-commit formatting after flake module migration (Feb 28 2026)
- After migrating from flake-parts to adios-flake, nixfmt-rfc-style requires reformatting
- `nix fmt` fixes all formatting; commit the result BEFORE running `nix flake check`
- The `pre-commit-run` check runs nixfmt on all tracked .nix files — one bad file blocks ALL checks
- `nix flake check` cascading failures: pre-commit-run failure makes ALL other checks appear to fail too

### Generation counting in Ion shell (Feb 20 2026)
- `grep -c '^[[:space:]]*[0-9]'` doesn't work reliably in Redox grep
- `wc -l` is more reliable for counting output lines
- `snix system generations` outputs: 5 header lines + N gen entries + 2 footer lines
- So `wc -l > 10` means at least 4 generation entries (header=5, footer=2, data≥4)

### C library cross-compilation for Redox (Feb 28 2026)
- Created `mk-c-library.nix` with `mkLibrary`, `mkAutotools`, `mkCmake` helpers
- Cross-env: CC=clang, AR=llvm-ar, CFLAGS includes `--target=x86_64-unknown-redox --sysroot=relibc/...`
- CRITICAL: C library builds CANNOT build test/app binaries — they need full libc linking
  but our LDFLAGS have `-nostdlib -static`. Build only `.a` targets, install manually.
- zlib: `./configure` uses `CHOST` env var for cross-detection. `make libz.a` for lib-only.
  The pkgconfig prefix varies — use `sed` not `substituteInPlace` for robustness.
- zstd: `make -C lib libzstd.a HAVE_PTHREAD=0` — the shared lib build uses `--noexecstack`
  flag that clang doesn't support. `lib-mt` target builds both static+shared — avoid it.
- expat: autotools needs `doc/Makefile.in` stub + correct timestamp ordering to prevent regen.
  `touch aclocal.m4; sleep 1; touch configure expat_config.h.in; sleep 1; touch Makefile.in`
  The `sleep 1` matters — Nix timestamps can all be epoch-zero otherwise.
- OpenSSL (Redox fork): Configure args after target go into CFLAGS — don't put `--with-rand-seed`
  there, it becomes a clang arg. `make build_generated` then `make libcrypto.a libssl.a || true`
  because the Makefile also tries to link apps/openssl which fails. Verify .a files exist after.
- `fetchurl` hashes: always wrong on first try. Get the real hash from the error message.
- `dontFixup = true` prevents patchelf from running on cross-compiled outputs.
- Tarball sources need extraction step — either `pkgs.stdenv.mkDerivation` to pre-extract,
  or manual `tar xf` in configurePhase. Can't use `cp -r ${src}/* .` on a .tar.gz.

### CC wrapper -nostdlib for C binaries (Feb 28 2026)
- The CC wrapper in mk-c-library.nix MUST add `-nostdlib` to prevent the host glibc's
  crt1.o/crti.o from being linked. Without it, binaries get BOTH host and relibc CRT files
  → duplicate _start, _init, _fini symbols.
- HOWEVER, `-nostdlib` in LDFLAGS breaks autotools configure tests — they try to compile+link
  tiny programs to detect functions like getopt(), getenv(), etc. With -nostdlib, link fails
  → configure reports "getopt not found" → build aborts.
- Solution: CC wrapper adds `-nostdlib` at the LINKER level (inside the wrapper), but
  packages that need configure tests use `crossEnvSetupWithWrapper` which puts the wrapper
  as CC (handles CRT injection). Then in preConfigure, override CC with the wrapper and set
  LDFLAGS WITHOUT -nostdlib (just `--target --sysroot -L -static -fuse-ld=lld`).
- ncurses: needed CC wrapper override in preConfigure + `--disable-widec` (relibc lacks wint_t)
  + stub man file inputs (man/man_db.renames.in, man/MKncu_config.in)
- readline: needed CC wrapper override + stub doc/Makefile.in + tarball hash fix
  (sha256-0rMVaEhcPF0ZcL1pyWpTNsAMX2MWX7eHMcJEBh68sH8= → sha256-dQ1DcYUob0CjaeHk9HZO2pMrlFm17JpzFig5PdPTIzQ=)

### bash 5.2 cross-compilation for Redox (Feb 28 2026)
- bash 5.2.15 = 5.0MB static ELF for x86_64-unknown-redox (with readline+ncurses)
- Dependency chain: relibc → ncurses → readline → bash
- Patching approach: Python (not sed!) for complex multi-line patches. Sed with `\|` and
  `\n` in replacement strings is unreliable inside Nix heredocs due to quoting layers.
- Key patches (from upstream Redox cookbook):
  1. bashline.c: disable group completion on Redox
  2. ulimit.def: guard HAVE_RESOURCE with !__redox__
  3. config-top.h: BROKEN_DIRENT_D_INO
  4. configure: disable bash_malloc for redox*
  5. posixwait.h: force POSIX wait types
  6. lib/readline/input.c: HAVE_SELECT fallback (variable declarations + condition)
  7. lib/readline/terminal.c: __redox__ guard
  8. lib/sh/getcwd.c: disable custom getcwd
  9. lib/sh/strtoimax.c: disable entirely (relibc provides it)
  10. parse.y + y.tab.c: comment out shell_input_line_property references (HANDLE_MULTIBYTE only)
- Build tool separation: `CC_FOR_BUILD=gcc` + `sed -i 's/-DHAVE_CONFIG_H//' builtins/Makefile`
  + `sed -i 's/CC_FOR_BUILD = .*/CC_FOR_BUILD = gcc -std=gnu89/' builtins/Makefile`
  because config.h is for the cross target, not the host, and GCC 15 rejects K&R declarations.
- Clang flags: `-Wno-error -Wno-implicit-function-declaration -Wno-implicit-int -Wno-deprecated-non-prototype`
- Duplicate symbol (mktime): `--allow-multiple-definition` in LDFLAGS
- Timestamp fix: `find . -type f -exec touch -t 202501010000 {} +` then `touch configure`
  (configure must be newer than configure.ac to prevent autotools regen)
- doc/Makefile.in stub needed (same as readline/ncurses pattern)

### Foundation C libraries — libpng, pcre2, freetype2, sqlite3 (Feb 28 2026)
- libpng 1.6.46: autotools, depends on zlib. GitHub archive needs `autoreconf -fi`.
  Test programs use `feenableexcept` (not in relibc) — build only `libpng16.la` target.
  Manual install of .a, headers, pkg-config (skip libtool's make install which builds tests).
- pcre2 10.45: autotools. Has ~80 doc files referenced in Makefile. `autoreconf -fi` regenerates
  the Makefile.in with doc targets we don't have. Fix: `sed -i '/^dist_doc_DATA/,/^$/d'` and
  `sed -i 's/ doc\/[^ ]*//g'` to strip doc references from Makefile.in before configure.
- freetype2 2.13.3: cmake (upstream uses meson but cmake also works). Pass explicit
  `-DZLIB_LIBRARY=`, `-DPNG_LIBRARY=` paths. Disable harfbuzz/brotli/bzip2. Builds clean.
- sqlite3 3.49.1: amalgamation build (single sqlite3.c). No configure needed — just
  `$CC $CFLAGS -c sqlite3.c` then `$AR rcs libsqlite3.a sqlite3.o`. Trivial cross-compile.
  Use `-DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_THREADSAFE=0 -DSQLITE_OS_UNIX=1`.
- All four use crossEnvSetup (raw clang, not wrapper) except libpng which needs
  crossEnvSetupWithWrapper for configure link tests.

### git 2.13.1 cross-compilation for Redox (Feb 28 2026)
- 6.4MB static ELF with 166 subcommands (git-add, commit, push, clone, etc.)
- Dependencies: curl + expat + openssl + zlib (all previously built)
- REG_STARTEND: relibc's regex.h lacks it. Define `REG_STARTEND 0` in git-compat-util.h
  after `#include <regex.h>`. Then override configure's `NO_REGEX` in config.mak.autogen
  AFTER configure runs (configure detects missing REG_STARTEND and sets NO_REGEX=YesPlease).
  The bundled compat/regex is broken because its `regex.c` does `#include <regex.h>`
  (angle brackets) which finds relibc's version due to `--sysroot` include precedence.
  Even `"regex.h"` (quotes) didn't fix it reliably with sysroot. Best approach: use system
  regex with REG_STARTEND=0 as no-op flag.
- config.mak.autogen overrides MUST be appended AFTER `./configure` runs, not before.
  Configure writes this file — appending before gets overwritten.
- `struct ustar_header`: forward-declared in `get-tar-commit-id.c` but never defined.
  relibc's `tar.h` also redefines `RECORDSIZE` with a different value.
  Fix: `#undef RECORDSIZE` before redefine, and add full struct definition inline.
- `-liconv`: configure detects iconv and adds it. Override with `NO_ICONV = 1` and
  `NEEDS_LIBICONV =` (empty) in config.mak.autogen.
- `NO_PERL = 1`: no perl on Redox. Without this, make tries `/usr/bin/perl` and fails.
- Python patching for complex Redox patches (terminal.c prompt, daemon.c syslog guards,
  git-compat-util.h SIG defines, /dev/null → /scheme/null, setup.c setsid guard).
  terminal.c patched via separate heredoc `python3 << 'PYEOF'` to avoid Nix `''` string issues.
- Makefile hard-link removal: Redox lacks hard links. Use grep+sed to delete `ln "$<"` lines,
  keeping `ln -s` (symlink) fallbacks.
- Nix `''` string quoting: Python `''` (empty string) terminates Nix heredoc strings.
  Use heredoc `<< 'PYEOF'` for Python code containing `''`.

### gnu-make cross-compilation for Redox (Feb 28 2026)
- gnu-make 4.4 = 3.9MB static ELF for x86_64-unknown-redox
- Used mkAutotools from mk-c-library.nix (simpler than bash — no dependency chain)
- Key patch: `#define ELIDE_CODE` before `#include "getopt.h"` in src/main.c
  (gnu-make bundles getopt.h/getopt.c which conflict with relibc's getopt)
- `touch Makefile.in configure` to prevent autotools regeneration
- doc/make.1 stub to satisfy Makefile reference
- `--disable-nls --without-guile --disable-job-server --disable-load` for minimal Redox build

### Batch package addition — pure Rust packages (Feb 28 2026)
- 10 new packages added in one batch, 3 more attempted but disabled
- Pattern: create .nix file → add flake input → wire in packages.nix → get vendor hash → fix → build
- Dummy hash `sha256-0000...` triggers hash mismatch error that reveals the real hash
- `mkMultiBinary` had a bug: passed `binaries` arg through to `mkPackage` which rejected it
  Fix: `builtins.removeAttrs args ["binaries"]` before forwarding (same pattern as `mkBinary`/`binaryName`)
- `fetchCargoVendor` ONLY works when Cargo.lock exists — perg (0.6.0) has none → build fails at vendor stage
- Git dependencies: adding `gitSources` to package args configures the cargo vendor config to map git URLs
  to the vendor directory. Without this, offline build can't find git deps → "can't checkout in offline mode"
- ring crate from git: needs `pregenerated/` assembly files that aren't in crates.io registry download
  The vendor dir only has registry sources, not full git checkout → assembly files missing → clang error
  This blocks pkgutils (depends on ring for TLS). Would need special handling to include git source.
- rustc-serialize: ancient crate, doesn't compile on Rust nightly 2025+ (lifetime errors)
  Blocks redox-ssh which depends on it. Would need upstream update or fork.
- Parallel vendor hash discovery: `nix build .#pkg 2>&1 | grep 'got:'` in backgrounded loops
  BUT backgrounded output interleaves — better to run sequentially with labeled output
- All packages should use `...` in their function params to accept standaloneCommon extras silently

### curl cross-compilation for Redox (Feb 28 2026)
- curl 8.11.1 cross-compiled with 1-line Redox patch (adds `__redox__` to sys/select.h guard)
- Three cross-compilation challenges solved:
  1. **Host CRT contamination**: Nix-wrapped clang picks up HOST glibc's crt1.o even with `--sysroot`
     because clang doesn't recognize `x86_64-unknown-redox` as a standard target for CRT search.
     Fix: CC wrapper script that adds relibc CRT files for link steps only.
  2. **relibc stdatomic.h incompatibility**: `_Atomic(int)` builtins in clang don't work with
     relibc's stdatomic.h macros. Fix: `ac_cv_header_stdatomic_h=no` in configure → falls to pthread lock.
  3. **libtool strips -static and rejects .o in LDFLAGS**: libtool removes `-static` from LDFLAGS
     (thinks it knows better) and rejects CRT .o files as "non-libtool objects".
     Fix: CC wrapper adds both `-static` and CRT files — they can't be stripped.
- CC wrapper pattern (reusable for any C binary cross-compiled to Redox):
  ```bash
  # Compile-only: pass through to real clang
  for arg in "$@"; do case "$arg" in -c|-S|-E|-M|-MM) exec clang "$@" ;; esac; done
  # Link step: add CRT + force static
  exec clang -static $SYSROOT/lib/crt0.o $SYSROOT/lib/crti.o "$@" -l:libc.a -l:libpthread.a $SYSROOT/lib/crtn.o
  ```
- `-l:libc.a` (GNU linker extension) forces static libc when both libc.a and libc.so exist in sysroot
- Output: 6.6MB static ELF binary + 1.1MB libcurl.a + headers + pkg-config
- Protocols: FILE HTTP HTTPS IPFS IPNS WS WSS (no FTP/SMTP/IMAP — disabled)
- Wired into development profile as a managed package (not boot-essential)

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

### GNU coreutils cross-compilation for Redox (gnulib issues) (Mar 1 2026)
- **gnulib circular include chain**: `lib/stddef.h → relibc/stddef.h → lib/stdint.h → relibc/sys/types.h → relibc/bits/pthread.h → needs size_t → not defined yet`. Fix: replace ONLY `lib/stddef.h` and `lib/stdint.h` with `#include_next` pass-throughs. Do NOT replace all gnulib headers — the others provide needed definitions (O_BINARY, mbscasecmp, file-type macros etc.)
- **LDBL_DIG missing**: gnulib's `vasnprintf.c` needs it. gnulib's `lib/float.h` wrapper doesn't pass through to compiler builtin. Fix: `-DLDBL_DIG=__LDBL_DIG__` in CFLAGS uses clang's builtin directly.
- **mktime/tzset duplicates**: configure guesses `mktime` is broken during cross-compilation and compiles replacements that conflict with relibc. Fix: `gl_cv_func_working_mktime=yes gl_cv_func_tzset_clobber=no` configure cache variables.
- **timezone_t/mktime_z/tzalloc**: Not in relibc. Need stub `lib/time_rz.c` — but do NOT use inline stubs in headers if gnulib has `time_rz.c` (will conflict). Replace gnulib's `time_rz.c` with stub implementations.
- **AT_EACCESS / O_SEARCH**: POSIX constants missing from relibc. Fix: `-DAT_EACCESS=0x200 -DO_SEARCH=O_RDONLY` in CFLAGS.
- **autoreconf vs config.sub-only**: Full autoreconf with gnulib works for newer packages (sed 4.4) but older packages (patch 2.7.6, diffutils 3.6) can get worse with autoreconf pulling in newer gnulib that has more incompatibilities. Safer approach: just replace `build-aux/config.sub` using `pkgs.gnu-config` + timestamp fixup to prevent autotools regeneration.
- **Tab vs space in patches**: GNU source files use tabs for indentation. Python patch scripts must match exact whitespace. Use `\t` in Python strings, not spaces.
- **Build order**: configure → apply gnulib fixes → make. Header replacements must happen AFTER configure generates Makefiles (which record header dependencies) but BEFORE make compiles.
- **Successfully built**: diffutils 3.6 (diff, cmp, diff3, sdiff), sed 4.4, patch 2.7.6 — all static ELF x86_64-unknown-redox

### Tier 1 foundation C libraries batch (Mar 1 2026)
- **All 12 built**: libiconv, gettext, bzip2, lz4, xz, libffi, libjpeg, libtiff, libgif, libwebp, pixman, harfbuzz
- **libjpeg headers**: libjpeg-turbo puts source headers in `src/` not root. `find .. -name "header.h"` works;
  `find .. -maxdepth 1` misses them. Missing `jerror.h` caused libtiff failure.
- **libtiff cmake CXX**: cmake option to disable C++ wrapper is `cxx=OFF` (not `tiff-cxx=OFF`).
  Found via `grep -i 'option.*cxx'` in cmake/CXXLibrary.cmake.
- **libtiff FindCMath**: relibc includes math functions in libc (no separate libm).
  Replace `cmake/FindCMath.cmake` with `set(CMath_FOUND TRUE)` stub.
- **cmake cross include paths**: `-DJPEG_INCLUDE_DIR=path` tells cmake WHERE to find the package
  but does NOT automatically add `-I` flags to compilation commands when `CMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY`.
  Must also set `CMAKE_C_STANDARD_INCLUDE_DIRECTORIES` or put deps in `CMAKE_C_FLAGS` directly.
- **gettext gnulib conflict**: Full gettext build pulls in gnulib which has wchar.h/stdint.h wrappers
  that conflict with relibc include chain. Solution: compile ONLY the minimal libintl source files
  manually (bindtextdom, dgettext, gettext, etc.) with a hand-written config.h. Skip gnulib entirely.
- **gettext libintl.h generation**: Header is generated from `libgnuintl.in.h` template with @VAR@ substitution.
  Must generate it explicitly; `make install` of the full gettext would do this but we skip it.
  Use Python for substitution (Nix `''` strings eat `@''` in sed patterns).
- **libpng broken symlink**: `ln -sf libpng16.pc libpng.pc` creates a symlink, but if libpng16.pc
  doesn't exist as a real file (only as a libtool-generated path), the symlink is dangling.
  Fix: `cp` instead of `ln -sf` for pkg-config compatibility files.
- **harfbuzz C++ stubs**: HarfBuzz is C++ internally (uses type_traits, atomic, initializer_list, etc.)
  but relibc has no C++ standard library. Full libc++ headers DON'T WORK because `#include_next`
  chain for float.h/math.h breaks when cross-compiling with custom sysroot.
  Solution: minimal hand-written C++ header stubs in a `runCommand` derivation. Provide ONLY
  what harfbuzz needs: type_traits (38 traits), atomic (single-threaded), initializer_list,
  new (placement new), memory (addressof), utility (move/forward/swap), algorithm (upper_bound),
  functional (hash for all integer/float types), mutex (no-op stubs).
  Key: `std::addressof` must handle const types; `std::hash<float>` uses memcpy to bits.
  Compile with `-nostdinc++ -I$stubs -isystem $clangResDir -fno-exceptions -fno-rtti -DHB_NO_MT`.
- **harfbuzz `addressof` redefinition**: Had it in both `<new>` and `<memory>`. Keep only in `<memory>`.
- **meson pkg-config for cross builds**: meson ignores PKG_CONFIG_LIBDIR env var during cross compilation.
  The `pkg-config` binary in the cross file must be an absolute path (relative paths fail with
  "Did not find pkg-config by name"). BUT even with absolute path, dependency chain (freetype2→zlib+libpng)
  fails if those deps' .pc files aren't in the search path. Ended up building harfbuzz with cmake instead.
- **cmake vs meson**: cmake handles cross-compilation better for our use case (can pass all flags
  via -DCMAKE_*_FLAGS). meson's cross file + property system is more opinionated and harder to debug.
- **xz**: mkAutotools with CC wrapper. Straightforward build.
- **lz4/bzip2**: mkLibrary (manual build phases). lz4 uses `make -C lib` with LIB_CFLAGS/AR/RANLIB.
  bzip2 uses `make libbz2.a` with CC/AR/RANLIB env vars.
- **libffi**: mkAutotools. GitHub archive needs `autoreconf -fi`. Disable test/man/doc subdirs.
- **libgif**: mkLibrary with manual compilation of `dgif_lib.c egif_lib.c gifalloc.c gif_err.c
  gif_font.c gif_hash.c openbsd-reallocarray.c`. Skip utilities that need linked executables.
- **pixman**: mkAutotools. `--disable-arm-a64-neon --disable-arm-iwmmxt --disable-arm-neon
  --disable-arm-simd` to avoid ARM-specific code. Builds clean for x86_64.
- **libwebp**: mkCmake. Simple cmake build with `-DWEBP_BUILD_CWEBP/DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF`
  to skip tool binaries. Produces 5 libraries: libsharpyuv, libwebp, libwebpdecoder, libwebpdemux, libwebpmux.

### Graphics stack fixes: gettext, glib, fontconfig (Mar 2 2026)
- **gettext libintl was empty**: Build compiled 20+ files with `2>/dev/null` error suppression
  — almost all failed silently due to gnulib deps. Only `hash-string.c` and `plural-exp.c` survived.
  Fix: Redox is C-locale only, so replace with stub implementations that pass through msgid.
  10 functions: gettext, dgettext, dcgettext, ngettext, dngettext, dcngettext, textdomain,
  bindtextdomain, bind_textdomain_codeset, plus locale_charset.
- **gettext installPhase `find ../../`**: Old buildPhase `cd gettext-runtime/intl` then installPhase
  used `find ../.. -name 'libgnuintl.in.h'`. New buildPhase stays in top dir, so `../../` traverses
  to `/proc` (sandbox). Fix: reference `${extractedSrc}` directly for template path.
- **glib gunixmounts.c**: The `#error` lines are at FILE scope (each platform provides the full
  function def under its own `#if`). Replacing `#error` with `return NULL;` puts return at file scope.
  Must provide COMPLETE function definitions: `static GList *\n_g_get_unix_mounts(void)\n{...}`.
- **glib mount_points**: `_g_get_unix_mount_points` has NO separate `#error`. It's defined inside
  the same `#if` chain as `g_get_mount_table`. The `#error No g_get_mount_table()` covers BOTH.
  Replace with `_g_get_unix_mount_points` stub (which is what's actually needed).
- **glib _g_get_unix_mounts signature**: Forward declaration at line 165 says `(void)`, not
  `(GUnixMountEntry **mount_point)`. Stub must match: `_g_get_unix_mounts(void)`.
- **glib openat stubs**: `-Werror,-Wmissing-prototypes` requires prototypes before definitions.
  Add both prototype declarations AND implementations in `_redox_stubs.c`.
- **glib get_mtab_monitor_file stub**: Added before any `#include`, so `NULL` undefined.
  Use `(const char *)0` instead.
- **Python `'''` in Nix `''` strings**: Triple-single-quotes contain `''` which terminates
  Nix indented strings. Use Python double-quoted strings with `\n` for multiline content.
- **Nix `echo ''`**: Also terminates Nix `''` string. Use `echo ""` instead.
- **fontconfig 2.16.0 hash changed**: `sha256-Y/...` → `sha256-ajPc...`
- **fontconfig missing doc stubs**: `doc/Makefile.in` and `doc/version.sgml.in` needed.
- **fontconfig LIBS needs -L paths**: `LIBS="-lpng -lz"` missing search paths.
  Fix: `LIBS="-L${redox-libpng}/lib -lpng -L${redox-zlib}/lib -lz"`
- **fontconfig C99 wchar_t probe**: `ac_cv_prog_cc_c99=` and `ac_cv_prog_cc_c11=` skip
  the probe that uses `wchar_t` (undefined in relibc without explicit include).

### snix-eval upstream update to eee47792 (Mar 1 2026)
- Updated from commit 6959c488 → eee47792 (12 upstream commits)
- Key new features: `__curPos` implementation, path interpolation (`./path/${var}`), `dirs` crate removed
- rnix parser 0.12 → 0.14: `ast::Path` split into `PathAbs/PathHome/PathRel/PathSearch`, `rnix::parser::ParseError` → `rnix::ParseError`
- nix-compat: `ExportedPathInfo` dropped global `rename_all = "camelCase"`, uses per-field `#[serde(rename)]` instead
- **Nix 2.31 FOD reference check regression**: `fetchCargoVendor` with git dependencies (snix-eval from git.snix.dev)
  creates a staging FOD containing the full git checkout, which includes test fixture files with `/nix/store/` paths.
  Nix 2.31's reference scanner flags these, blocking hash discovery (can't use fake-hash-then-check method).
  - Error: `fixed-output derivations must not reference store paths`
  - The check only fires on hash MISMATCH — correct hash skips it — but you can't discover the correct hash!
  - Old builds were cached with correct hash so never triggered the check
- **Fix: vendor snix-eval locally** instead of using git dependency in Cargo.toml
  - Copied snix-eval + snix-eval-builtin-macros from upstream at eee47792
  - Converted `workspace = true` deps to explicit version numbers
  - Applied Redox OS patch (`is_second_coordinate` includes `"redox"`) directly in vendored source
  - Removed test fixtures (3.5MB → 680KB), disabled `mod tests` in lib.rs
  - `#[cfg(test)]` attribute was silently gating the next non-commented line — commenting out `mod tests`
    caused `use rustc_hash::FxHashMap` to become test-only! Fixed by commenting out the `#[cfg(test)]` too.
  - `rustc-hash` 2.x needs `features = ["std"]` for `FxHashMap` type alias (moved behind feature gate)
  - No more git sources in Cargo.lock → no `gitSources` needed in snix.nix → no `postConfigure` patching
  - Binary: 4.8MB static ELF (was 4.0MB — slight increase from new features + rnix 0.14)
  - 206 host unit tests pass, cross-compilation succeeds
- `dirs` crate removal is great for Redox: home dir now resolved via `EvalIO::get_env("HOME")`
  which maps to relibc's `getenv()` — no more platform-specific `dirs-sys` → `redox_users` chain
- The `fetch-cargo-vendor-util create-vendor-staging` can be run manually outside a FOD
  to compute hashes: set `PATH` to include `fetch-cargo-vendor-util`, `nix-prefetch-git`;
  set `SSL_CERT_FILE` to cacert bundle
