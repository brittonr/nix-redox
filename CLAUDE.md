# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a RedoxOS build environment using Nix flakes. The project contains:
- A complete Nix-based build system for RedoxOS (replacing Make/Podman workflows)
- Various build scripts for relibc and cross-compilation toolchain setup
- Integration with Nixtamal for input pinning

## Reference Documentation

### SNIX Reference (snix-analysis.md)

Reference `snix-analysis.md` when:
- Discussing alternative Nix implementations or Nix internals
- Considering content-addressed storage for the build system
- Exploring modular/protocol-based architecture patterns
- Comparing bytecode VMs vs AST interpreters
- Designing pluggable build backends (OCI, gRPC, microVM)
- Understanding how Nix evaluation, derivations, and stores work

Key concepts covered: snix-eval bytecode VM, snix-castore content-addressed storage, snix-build protocol, EvalIO trait pattern, BuildService backends.

## External Resources

- **Official Package Repository**: https://static.redox-os.org/pkg/x86_64-unknown-redox/
- **Porting Applications Guide**: https://doc.redox-os.org/book/porting-applications.html
- **Porting Case Study**: https://doc.redox-os.org/book/porting-case-study.html
- **Libraries and APIs**: https://doc.redox-os.org/book/libraries-apis.html
- **Developer FAQ**: https://doc.redox-os.org/book/developer-faq.html
- **Build System Reference**: https://doc.redox-os.org/book/build-system-reference.html
- **Build Phases**: https://doc.redox-os.org/book/build-phases.html
- **Troubleshooting**: https://doc.redox-os.org/book/troubleshooting.html
- **Boot Process**: https://doc.redox-os.org/book/boot-process.html

## Architecture

### Directory Structure
- `/` - Root contains Nix flake configuration and build scripts
- `redox-src/` - RedoxOS source tree (when cloned)
- `nix/tamal/` - Nixtamal configuration for input management
- `nix/pkgs/` - Package definitions (host, system, userspace, infrastructure)
- `nix/redox-system/` - Adios-based module system for declarative configuration (primary system builder)
- `nix/vendor/adios/` - Vendored [adios](https://github.com/adisbladis/adios) module system by [@adisbladis](https://github.com/adisbladis)
- `nix/vendor/korora/` - Vendored [Korora](https://github.com/adisbladis/adios) type system (standalone, no nixpkgs dependency)
- `nix/flake-modules/` - Flake-parts modules for build system integration

### Key Components (from flake.nix)

The Nix flake builds RedoxOS components in dependency order:
1. **Host Tools**: cookbook, redoxfs, installer - tools that run on the build machine
2. **Cross-compilation Toolchain**: relibc (C library), sysroot vendoring
3. **System Components**: kernel, bootloader, base (essential system binaries)
4. **Boot Infrastructure**: bootstrap loader, initfs (initial RAM filesystem)
5. **Disk Image**: Complete bootable UEFI disk image

### Cross-compilation Target
- Primary target: `x86_64-unknown-redox`
- Uses LLVM/Clang toolchain with custom linker scripts
- Requires `-Z build-std` for building Rust standard library

## Common Commands

### Building with Nix

```bash
# Build host tools (works with standard sandbox)
nix build .#cookbook    # Package manager
nix build .#redoxfs     # Filesystem tools
nix build .#fstools     # All host tools combined

# Cross-compiled components (all work with standard sandbox)
nix build .#relibc
nix build .#kernel
nix build .#bootloader
nix build .#base

# Disk images (all built through the adios module system)
nix build .#redox-default     # Development profile (auto networking, CLI tools)
nix build .#redox-minimal     # Minimal (ion + uutils only, no network)
nix build .#redox-graphical   # Orbital desktop + audio
nix build .#redox-cloud       # Cloud Hypervisor optimized (static IP, virtio-only)
nix build .#diskImage         # Alias for redox-default

# Run in Cloud Hypervisor (default - Rust-based VMM with lower overhead)
nix run .#run-redox            # Headless mode with serial console (Cloud Hypervisor)
nix run .#run-redox-graphical  # Graphical mode with QEMU GTK display

# Profile-specific runners
nix run .#run-redox-default           # Development profile in Cloud Hypervisor
nix run .#run-redox-default-qemu      # Development profile in QEMU headless
nix run .#run-redox-minimal           # Minimal profile in Cloud Hypervisor
nix run .#run-redox-cloud             # Cloud profile headless (no TAP)
nix run .#run-redox-cloud-net         # Cloud profile with TAP networking
nix run .#run-redox-graphical-desktop # Graphical profile with QEMU GTK display
nix run .#run-redox-graphical-headless # Graphical profile headless (test drivers)

# Cloud Hypervisor variants
nix run .#run-redox-cloud-hypervisor-net  # With TAP networking (requires setup)
nix run .#run-redox-cloud-hypervisor-dev  # Development mode with API socket

# QEMU variants (legacy)
nix run .#run-redox-qemu       # QEMU headless mode

# Cloud Hypervisor networking setup (run once as root)
sudo nix run .#setup-cloud-hypervisor-network  # Creates TAP interface with NAT

# redox-rebuild: System configuration manager (like nixos-rebuild / darwin-rebuild)
nix run .#redox-rebuild -- build                 # Build default profile toplevel
nix run .#redox-rebuild -- build minimal         # Build minimal profile
nix run .#redox-rebuild -- run                   # Build + launch VM
nix run .#redox-rebuild -- run graphical         # Build + launch graphical VM
nix run .#redox-rebuild -- test                  # Build + automated boot test
nix run .#redox-rebuild -- diff                  # Show what changed vs current generation
nix run .#redox-rebuild -- check                 # Run assertions + system checks only
nix run .#redox-rebuild -- list-generations      # Show build history
nix run .#redox-rebuild -- list-generations --json  # JSON output
nix run .#redox-rebuild -- rollback              # Switch to previous generation
nix run .#redox-rebuild -- rollback 1            # Switch to specific generation
nix run .#redox-rebuild -- repl                  # Nix repl with system config
nix run .#redox-rebuild -- version               # Show current system version info
nix run .#redox-rebuild -- changelog             # Show recent module system git changes
nix run .#redox-rebuild -- edit                  # Open flake.nix in $EDITOR

# Build bridge: live package push to running VM via virtio-fs
nix run .#run-redox-shared                       # Boot VM with virtio-fs shared directory
nix run .#push-to-redox -- ripgrep               # Build + push one package to shared cache
nix run .#push-to-redox -- ripgrep fd bat        # Push multiple packages
nix run .#push-to-redox -- --all                 # Push all available packages
nix run .#push-to-redox -- --list                # List available + cached packages
nix run .#build-bridge                           # Host-side daemon for in-guest rebuild requests

# Guest side (inside Redox VM with shared filesystem):
#   snix search --cache-path /scheme/shared/cache
#   snix install ripgrep --cache-path /scheme/shared/cache
#   # Or set env var once: export SNIX_CACHE_PATH=/scheme/shared/cache
#   snix install ripgrep
```

### Development Shells

```bash
# Enter development shell
nix develop          # Default pure Nix environment
nix develop .#native # Full native environment with all tools
nix develop .#minimal # Minimal environment

# Legacy nix-shell
nix-shell           # Default shell
nix-shell -A native # Native shell
```

### Build Scripts (Legacy/Debug)

```bash
./build-env.sh       # Set up build environment without patchelf
./build-relibc.sh    # Build relibc manually
./build-simple.sh    # Simple build attempt
./build-with-wrappers.sh # Build with compiler wrappers
```

### RedoxOS Module System (nix/redox-system/)

A declarative module system for RedoxOS configuration, built on
[adios](https://github.com/adisbladis/adios) by
[@adisbladis](https://github.com/adisbladis) with
[Korora](https://github.com/adisbladis/adios) types.

Unlike NixOS's `lib.evalModules`, adios modules declare **explicit inputs** by
path — no global `config` namespace, no `lib.mkOption`/`lib.mkIf` machinery,
no nixpkgs dependency in the evaluator. Each module is a self-contained unit
that declares typed options (via Korora), names its dependencies, and provides
an `impl` function that receives evaluated inputs.

All option types use Korora's **compound type system**: `struct`, `enum`,
`listOf`, `attrsOf`, `optionalAttr` — not just primitives. This means
configuration errors are caught at evaluation time with precise error messages
(e.g., `"'bogus' is not a member of enum 'StorageDriver'"`).

```nix
# Usage in a Nix expression:
let
  redoxSystemFactory = import ./nix/redox-system;
  mySystem = redoxSystemFactory.redoxSystem {
    profiles = [ "development" ];
    overrides = {
      "/users" = {
        users.admin = { uid = 1001; gid = 1001; home = "/home/admin";
                        shell = "/bin/ion"; password = "redox"; };
      };
      "/networking" = {
        mode = "static";       # enum: auto | dhcp | static | none
        interfaces.eth0 = { address = "10.0.0.5"; gateway = "10.0.0.1"; };
      };
      "/environment" = {
        systemPackages = [ pkgs.helix pkgs.ripgrep ];
      };
    };
    pkgs = flatRedoxPackages;  # All cross-compiled Redox packages
    hostPkgs = nixpkgs;        # Build machine packages
  };
in mySystem.diskImage  # or .initfs, .toplevel
```

**Module system structure:**
- `nix/redox-system/default.nix` — `redoxSystem` entry point with `.extend` chaining
- `nix/redox-system/modules/` — Adios modules (auto-imported via `adios.lib.importModules`)
- `nix/redox-system/modules/build/` — Consolidated build module (rootTree, initfs, diskImage)
- `nix/redox-system/profiles/` — Option presets (development, minimal, graphical, cloud-hypervisor)
- `nix/redox-system/lib.nix` — Redox-specific helpers (passwd/group format, etc.)
- `nix/vendor/adios/` — Vendored adios module system
- `nix/vendor/korora/` — Vendored Korora type system

**Module tree (16 modules with explicit inputs):**
```
/pkgs          — Package injection (pkgs, hostPkgs, nixpkgsLib)
/boot          — Kernel, bootloader, initfs config         (inputs: /pkgs)
/hardware      — Driver selection with enum types           (no inputs)
/networking    — Network mode, DNS, interfaces              (no inputs)
/environment   — Packages, shell aliases, variables         (no inputs)
/filesystem    — Directory layout, symlinks                 (no inputs)
/graphics      — Orbital desktop config                     (no inputs)
/services      — Init scripts, startup                      (no inputs)
/users         — User accounts with struct types, groups    (no inputs)
/security      — Namespace access, setuid, policies         (no inputs)
/time          — Hostname, timezone, NTP, hwclock           (no inputs)
/programs      — Ion, helix, editor, httpd config           (no inputs)
/logging       — Log levels, destinations, retention        (no inputs)
/power         — ACPI, power/idle actions, panic behavior   (no inputs)
/snix          — stored/profiled daemons, build sandboxing  (no inputs)
/build         — Produces rootTree, initfs, diskImage       (inputs: all 15 above)
```

**Type system (Korora compound types):**
- `struct "User" { uid = int; gid = int; home = string; ... }` — Typed records
- `enum "StorageDriver" ["ahcid" "nvmed" "ided" "virtio-blkd"]` — Closed variants
- `enum "NetworkMode" ["auto" "dhcp" "static" "none"]` — Mode selection
- `enum "LogLevel" ["debug" "info" "warn" "error" "off"]` — Log levels
- `enum "PowerAction" ["shutdown" "reboot" "suspend" "none"]` — Power actions
- `enum "NamespaceAccess" ["full" "read-only" "none"]` — Scheme access control
- `struct "IonConfig" { enable = bool; prompt = string; initExtra = string; }` — Shell config
- `struct "HelixConfig" { enable = bool; theme = string; }` — Editor config
- `listOf (enum "GraphicsDriver" ...)` — Parameterized containers
- `attrsOf (struct "Interface" { address = string; gateway = string; })` — Typed maps
- `optionalAttr bool` — Optional struct fields (absent is ok, wrong type is not)

**Key options (by module path):**
- `/boot` — `kernel`, `bootloader`, `initfsExtraBinaries`, `initfsExtraDrivers`, `initfsEnableGraphics`
- `/users` — `users` (attrsOf User struct), `groups` (attrsOf Group struct)
- `/networking` — `enable`, `mode` (enum), `dns` (listOf string), `interfaces` (attrsOf Interface struct)
- `/hardware` — `storageDrivers` (listOf enum), `networkDrivers`, `graphicsDrivers`, `audioDrivers`
- `/environment` — `systemPackages` (listOf derivation), `variables`, `shellAliases` (attrsOf string)
- `/services` — `initScripts` (attrsOf InitScript struct), `startupScriptText`
- `/graphics` — `enable`, `resolution`
- `/security` — `namespaceAccess` (attrsOf enum), `setuidPrograms`, `protectKernelSchemes`, `requirePasswords`, `allowRemoteRoot`
- `/time` — `hostname`, `timezone`, `ntpEnable`, `ntpServers`, `hwclock` (enum)
- `/programs` — `ion` (IonConfig struct), `helix` (HelixConfig struct), `editor`, `httpd` (HttpdConfig struct)
- `/logging` — `level` (enum), `kernelLogLevel` (enum), `logToFile`, `logPath`, `maxLogSizeMB`, `persistAcrossBoot`
- `/power` — `acpiEnable`, `powerAction` (enum), `idleAction` (enum), `idleTimeoutMinutes`, `rebootOnPanic`
- `/snix` — `stored` (StoredConfig struct: enable, cachePath, storeDir), `profiled` (ProfiledConfig struct: enable, profilesDir, storeDir), `sandbox` (bool)

### Redox Scheme Daemons (snix)

snix includes three Redox-native scheme daemons that leverage the OS's namespace architecture:

- **`stored`** (`snix stored`) — Serves `/nix/store/` paths via the `store:` scheme with lazy NAR extraction on first access. Packages register in PathInfoDb at install time but don't decompress until something actually opens a file.
- **`profiled`** (`snix profiled`) — Presents union views of installed packages via the `profile:` scheme. No symlink farms — add/remove updates an in-memory BTreeMap and atomically persists a mapping.json. Mutations go through a `.control` write interface.
- **sandbox** — Restricts builder processes to declared inputs using Redox's native `setrens()` namespace syscalls. FOD detection gates network access. Stubbed until `libredox` is a target dependency.

**Fallback behavior**: When the daemons aren't running, snix behaves exactly as before — direct filesystem ops and symlink profiles. All scheme-specific code compiles only on Redox (`#[cfg(target_os = "redox")]`).

**CLI flags**:
- `snix build --no-sandbox` — Skip namespace sandboxing
- `snix install --lazy` — Register without extracting (requires `stored` daemon)
- `snix stored` / `snix profiled` — Run daemons manually

**Profile**: `scheme-native` profile enables all three capabilities on top of the development profile.

### Running Tests

```bash
# Automated boot test — boots minimal image, verifies milestones on serial
nix run .#boot-test              # Auto-detect (Cloud Hypervisor if KVM, else QEMU TCG)
nix run .#boot-test -- --qemu    # Force QEMU TCG (no KVM required, slower)
nix run .#boot-test -- --verbose # Show full serial output
nix run .#boot-test -- --timeout 120  # Custom timeout

# Functional test — boots test image, runs ~110 in-guest tests
nix run .#functional-test              # Auto-detect VMM
nix run .#functional-test -- --qemu    # Force QEMU TCG
nix run .#functional-test -- --verbose # Show serial output
nix run .#functional-test -- --timeout 180

# Bridge test — tests live package delivery via virtio-fs (30 tests)
nix run .#bridge-test              # Pushes packages, boots VM, tests snix install
nix run .#bridge-test -- --verbose # Show full serial output
nix run .#bridge-test -- --timeout 180

# Module system tests (fast, no cross-compilation)
nix build .#checks.x86_64-linux.eval-profile-default
nix build .#checks.x86_64-linux.eval-profile-functional-test
nix build .#checks.x86_64-linux.artifact-rootTree-has-passwd

# All checks (includes cross-compiled builds — slow)
nix flake check
```

Currently, Cargo tests are disabled in most packages due to cross-compilation. To run tests when available:
```bash
cargo test --target x86_64-unknown-redox
```

## Important Technical Details

### Vendor Management
The build uses offline Cargo vendoring with version-aware merging:
- Project dependencies are vendored first
- Sysroot dependencies (for `-Z build-std`) are merged with version conflict resolution
- Checksums are regenerated after vendor merging

### Linker Configuration
- Uses `ld.lld` (LLVM linker) for all Redox target builds
- Custom linker scripts for bootstrap loader
- Stub libraries for unwinding functions (since `panic=abort` is used)

### Known Issues and Workarounds

1. **Vendor Checksum Issues**: Git dependencies sometimes have incorrect checksums after vendoring. The build regenerates all checksums using Python scripts.

2. **Duplicate Symbols**: Uses `--allow-multiple-definition` linker flag to resolve conflicts between relibc's bundled core/alloc and `-Z build-std` versions

3. **UEFI AES Intrinsics Bug**: Bootloader forces software AES implementation with `--cfg aes_force_soft` to avoid LLVM codegen issues

## Nixtamal Integration

The project includes Nixtamal configuration in `nix/tamal/manifest.kdl` for input pinning. This manages nixpkgs versions and other dependencies with KDL-based configuration.

## Environment Variables

Key environment variables set by the build:
- `CARGO_BUILD_TARGET`: x86_64-unknown-redox
- `RUST_SRC_PATH`: Path to Rust standard library source
- `NIX_SHELL_BUILD=1`: Indicates Nix shell environment
- `PODMAN_BUILD=0`: Disables Podman-based builds

## Running and Testing

### Successful Boot Output

When running with `nix run .#run-redox` or after building the disk image, you should see:
1. UEFI bootloader starting
2. RedoxFS detection and mounting
3. Kernel initialization with memory detection
4. Driver initialization
5. "Redox OS boot complete!" message

### Expected Errors in Headless Mode

The following errors are normal when running in headless/serial console mode:
- **ps2d panic**: "No such device" - PS/2 driver fails because there's no keyboard/mouse in headless mode
- **PCIe info warning**: Falls back to PCI 3.0 configuration space
- These errors don't prevent the system from booting successfully

### Building and Running the Disk Image

```bash
# Build the complete disk image
nix build .#diskImage

# Run with Cloud Hypervisor (default - recommended)
nix run .#run-redox            # Cloud Hypervisor headless with serial console

# Run with QEMU (for graphical mode or legacy compatibility)
nix run .#run-redox-graphical  # QEMU graphical mode with GTK display
nix run .#run-redox-qemu       # QEMU headless mode (legacy)

# Or run manually with Cloud Hypervisor
cloud-hypervisor \
  --firmware /path/to/CLOUDHV.fd \
  --disk path=result/redox.img \
  --cpus boot=4 \
  --memory size=2048M \
  --serial tty \
  --console off

# Or run manually with QEMU
qemu-system-x86_64 \
  -m 2048 \
  -enable-kvm \
  -bios /path/to/OVMF.fd \
  -drive file=result/redox.img,format=raw \
  -nographic
```

### Running Modes

**Cloud Hypervisor (Default)** (`nix run .#run-redox`):
- Rust-based VMM with lower memory/CPU overhead
- Uses virtio-blk storage with direct I/O
- Serial console output
- Exit with Ctrl+C
- Environment variables: CH_CPUS, CH_MEMORY, CH_HUGEPAGES, CH_DIRECT_IO

**Cloud Hypervisor with Networking** (`nix run .#run-redox-cloud-hypervisor-net`):
- Requires TAP interface setup: `sudo nix run .#setup-cloud-hypervisor-network`
- Uses virtio-net with multi-queue for throughput
- Guest IP via DHCP (172.16.0.2/24)

**Cloud Hypervisor Development Mode** (`nix run .#run-redox-cloud-hypervisor-dev`):
- Enables API socket for runtime control
- Supports pause/resume, snapshot/restore, memory hotplug
- Use ch-remote or wrapper scripts: pause-redox, resume-redox, snapshot-redox

**QEMU Graphical Mode** (`nix run .#run-redox-graphical`):
- Opens a QEMU window with full graphics
- Interactive display resolution selection
- USB tablet and keyboard support for better input handling
- Close the window to quit

**QEMU Headless Mode** (`nix run .#run-redox-qemu`):
- Legacy mode for compatibility
- Uses serial console output
- Exit with Ctrl+A then X

## Build Bridge (virtio-fs live package delivery)

The build bridge enables an edit→build→deploy→test loop without disk image rebuilds.
Host-built packages are serialized to a binary cache and shared with a running Redox VM
via virtio-fs, then installed on the guest using `snix`.

### Architecture

```
Host                                    Guest (Redox VM)
─────────────────────                   ─────────────────────
nix build .#ripgrep                     /scheme/shared/cache/
  → NAR serialize + zstd compress         ├── packages.json
  → write to /tmp/redox-shared/cache/     ├── *.narinfo
                                          └── *.nar.zst
virtiofsd --shared-dir /tmp/redox-shared  │
  ↕ virtio-fs (FUSE over virtqueue)       │
Cloud Hypervisor (--fs tag=shared)        ↕
                                        virtio-fsd driver
                                          → /scheme/shared/
                                        snix install ripgrep
                                          → reads cache, unpacks NAR
```

### Key files
- `nix/pkgs/infrastructure/push-to-redox.nix` — Host tool: `nix build` → NAR → shared cache
- `nix/pkgs/infrastructure/bridge-test.nix` — End-to-end test orchestrator (30 tests)
- `nix/pkgs/system/virtio-fsd/src/` — Guest FUSE-over-virtqueue driver
- `nix/redox-system/profiles/bridge-test.nix` — Guest test script (Ion shell)
- `nix/lib/build-binary-cache.py` — Python NAR serializer

### virtio-fsd implementation notes
- **Response buffer sizing**: virtiofsd uses the response descriptor size to determine
  `preadv2()` length. Response buffers MUST be `sizeof(FuseOutHeader) + requested_size`.
- **DMA buffer leak**: Buffers are `core::mem::forget()`ed after each request to avoid a
  Redox kernel bug in `deallocate_p2frame` (page frame refcount corruption).
- **Flat cache layout**: NARs in cache root (not `nar/` subdirectory). narinfo `URL:` field
  rewritten from `nar/hash.nar.zst` to `hash.nar.zst` during merge.
- **Flag translation**: Redox flags (`O_RDONLY=0x10000`, `O_CREAT=0x02000000`) translated
  to Linux FUSE flags (`O_RDONLY=0`, `O_CREAT=0o100`) via `redox_to_fuse_flags()`.
- **Write support**: FUSE_WRITE (data in request descriptor), FUSE_CREATE (atomic
  create+open), FUSE_MKDIR, FUSE_UNLINK, FUSE_RMDIR, FUSE_SETATTR (truncate).
  Guest can create, write, overwrite, and delete files/dirs on the host.
- **O_CREAT + O_DIRECTORY**: Redox `mkdir()` goes through `openat` with these flags,
  handled specially to call FUSE_MKDIR then FUSE_OPENDIR.

## Ion Shell Reference

Ion is the default shell for Redox OS. It has different syntax from POSIX shells (bash/sh).

**Documentation**: https://doc.redox-os.org/ion-manual/

### Key Differences from POSIX Shells

- Variables use `let` not assignment: `let var = "value"` (NOT `var="value"`)
- Arrays use `@` sigil: `@array` (strings use `$var`)
- Control flow ends with `end` (NOT `fi`, `done`, `esac`)
- Use `else if` (NOT `elif`)
- No `then` keyword needed after `if`
- Environment variables must be explicitly exported

### Variables

```ion
# String variables
let name = "hello"
echo $name

# Array variables
let arr = [ one two three ]
echo @arr

# Type-checked variables
let flag:bool = true
let count:int = 42

# Export for environment
export PATH /bin:/usr/bin
```

### Control Flow

```ion
# If statement
if test $val = "foo"
    echo "found foo"
else if test $val = "bar"
    echo "found bar"
else
    echo "not found"
end

# For loop
for item in @array
    echo $item
end

# While loop
let i = 0
while test $i -lt 10
    echo $i
    let i += 1
end
```

### Process Expansions

```ion
# String output (like bash $())
let output = $(command args)

# Array output (splits by whitespace)
let items = [ @(ls) ]

# Split by lines
for line in @lines($(cat file))
    echo $line
end
```

### Conditionals and Tests

```ion
# File tests
if exists -f /path/to/file
    echo "file exists"
end

if exists -d /path/to/dir
    echo "directory exists"
end

# String comparison
if test $var = "value"
if is $var "value"

# Negation
if not exists -f /path
```

### Pipelines and Redirection

```ion
# Standard pipe
cmd1 | cmd2

# Redirect stdout
cmd > file.txt

# Redirect stderr
cmd ^> errors.txt

# Redirect both
cmd &> all.txt

# Append
cmd >> file.txt
```

### Common Builtins

- `echo` - print text
- `test` - evaluate expressions
- `exists` - check if files/dirs/vars exist
- `is` / `eq` - compare values
- `not` - negate exit status
- `matches` - regex matching
- `let` - variable assignment
- `drop` - delete variables
- `cd` - change directory
- `eval` - evaluate string as command
