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

### Minimal profile missing getty
- The minimal profile doesn't include `userutils` (which provides `getty` and `login`)
- init.rc ends with `/bin/getty debug:` which fails with "No such file or directory"
- Boot still succeeds (the "Boot Complete" message prints before getty runs)
- Not a blocker for boot testing, but the shell prompt milestone won't fire

## What Works
- 68 module system tests across 4 layers all pass
- Mock packages build in seconds, enabling fast iteration
- Type validation catches invalid enums, missing struct fields, and wrong types
- Artifact tests verify file content (semicolon-delimited passwd, init scripts, etc.)
- Automated boot test passes in ~3s using Cloud Hypervisor with KVM
