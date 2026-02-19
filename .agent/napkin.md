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

### base-src init rework (fc162ac, Feb 18 2026)
- base-src fc162ac reworked init: numbered init.d/ scripts replace init.rc
- SchemeDaemon API: nulld/zerod/randd/logd/ramfs use `scheme <name> <cmd>` not `notify`
- pcid-spawner now uses `--initfs` flag (shared config locator crate)
- pcid config moved from etc/pcid/ to etc/pcid.d/
- ipcd, ptyd, USB daemons are rootfs services — do NOT put in initfs init scripts
- acpid is spawned by pcid-spawner — do NOT notify it directly (causes "File exists" crash)
- Boot test bisecting caught the regression — exactly what it was built for
