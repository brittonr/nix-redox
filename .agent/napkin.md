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

### Wiring virtualisation module (bb4c172, Feb 19 2026)
- Build module returns vmConfig attrset; redoxSystem factory exposes it; system.nix passes to runner factories
- Runner factories accept `vmConfig ? {}` with `or` defaults for backward compatibility
- Cloud profile correctly flows `tapNetworking = true` through the entire chain
- QEMU runners: replace hardcoded `-m 2048 -smp 4` with `${defaultMemory}` `${defaultCpus}` from vmConfig

### Functional test suite design (Feb 19 2026)
- In-guest test approach: modify startupScriptText to run tests, avoids pty/expect entirely
- Tests output `FUNC_TEST:name:PASS/FAIL` to serial; host script polls the file (same pattern as boot test)
- Ion shell (not bash) runs the test script — `let var = val`, `if test ... end`, `exists -f`
- Startup script gets `#!/bin/sh` prepended by build module (sh→ion symlink on Redox)
- No `echo -e` in Ion — use separate echo statements or file writes for multi-line
- No `$$` in Ion for PID — use static test file names with fixed suffixes
- New profile `functional-test.nix` extends development with test runner
- `mkFunctionalTest` factory in infrastructure alongside `mkBootTest`
- Eval test for functional-test profile added to CI fast-checks tier

### base-src init rework (fc162ac, Feb 18 2026)
- base-src fc162ac reworked init: numbered init.d/ scripts replace init.rc
- SchemeDaemon API: nulld/zerod/randd/logd/ramfs use `scheme <name> <cmd>` not `notify`
- pcid-spawner now uses `--initfs` flag (shared config locator crate)
- pcid config moved from etc/pcid/ to etc/pcid.d/
- ipcd, ptyd, USB daemons are rootfs services — do NOT put in initfs init scripts
- acpid is spawned by pcid-spawner — do NOT notify it directly (causes "File exists" crash)
- Boot test bisecting caught the regression — exactly what it was built for
