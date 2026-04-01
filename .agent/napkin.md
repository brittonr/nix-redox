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

### Heredoc indentation in Nix `''` strings
- ONE column-0 line breaks ALL heredoc terminators. Every line needs N+ spaces for N-space stripping.
- `nix fmt` can silently re-indent and break heredocs. Verify after formatting.
- Inline Python in Nix strings breaks too — extract to .py files instead.

### Vendor hash must update in BOTH files
- `snix.nix` AND `snix-source-bundle.nix` need the same hash when Cargo.lock changes.

### `cp -r dir/*` drops dotfiles
- Use `cp -r dir/.` to copy ALL contents including dotfiles.
- `.cargo/config.toml` silently lost when `/*` was used.

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

### Rootfs oneshot services fail silently — boot-time networking blocked
- Services in `/usr/lib/init.d/` with type "oneshot" run after rootfs mount
- Service command executes (confirmed: binary exists, service file correct) but writes to netcfg scheme don't take effect
- Manual execution of identical command from login shell works perfectly
- Tried: netcfg-setup binary, Ion wrapper script, direct echo to scheme — all fail at boot, all work manually
- Root cause unknown — needs serial console or init debug logging to trace
- Possible causes: smolnetd scheme registration race, init env_clear side effects, Ion script execution in init context
- Workaround: run `/bin/netcfg-setup static-auto --address X --gateway Y` manually after login

### Ion `&>` redirect doesn't work
- `#!/bin/ion\ncommand &> /var/log/file.log` — the `&>` syntax doesn't capture output
- Log file is never created
- Same issue affects `dhcpd-quiet` wrapper (also uses `&>` in Ion)

## Active Workarounds (still needed)

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

### `$()` crashes on empty output
- `let var = $(grep ...)` → "Variable '' does not exist" when grep returns nothing.
- Use file-based or exit-code-based testing instead.

### `tail` does not exist on Redox
- Use `cat` or `head` (from extrautils) instead.

### Cargo build pipe exit codes lost
- `cargo build 2>&1 | while read` always exits 0 (pipe breaks).
- Use file redirection + `wait $PID` to get real exit code.
