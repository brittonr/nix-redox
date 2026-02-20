# RedoxOS — Pure Nix Build

A complete, reproducible build system for [Redox OS](https://www.redox-os.org/)
using Nix flakes. Replaces the traditional Make/Podman workflow with pure Nix
derivations — every component from relibc through the bootable disk image is
built hermetically.

## Quick Start

```bash
# Build and boot Redox (headless, serial console)
nix run .#run-redox

# Build and boot with a graphical display
nix run .#run-redox-graphical

# Build just the disk image
nix build .#diskImage
```

The default runner uses [Cloud Hypervisor](https://www.cloudhypervisor.org/) for
its low overhead and memory-safe implementation. Graphical mode uses QEMU for
better input device support.

## What's in the Image

The disk image is a 512 MB GPT disk with a UEFI boot partition and a RedoxFS
root filesystem containing:

| Category | Packages |
|---|---|
| **Boot** | bootloader, kernel, initfs |
| **System** | base (init, drivers, daemons), relibc |
| **Shell** | ion (default shell) |
| **Coreutils** | uutils (Rust coreutils), binutils, extrautils |
| **Editors** | helix, sodium |
| **Network** | netutils (dhcpd, dnsd, ping, ifconfig, nc) |
| **CLI Tools** | ripgrep, fd, bat, hexyl, zoxide, dust |
| **User Mgmt** | userutils (getty, login, passwd, su, sudo) |
| **Graphics** | orbital, orbterm, orbutils, orbdata *(graphical image only)* |

## Running

| Command | Description |
|---|---|
| `nix run .#run-redox` | Cloud Hypervisor, headless with serial console *(default)* |
| `nix run .#run-redox-graphical` | QEMU with GTK graphical display |
| `nix run .#run-redox-qemu` | QEMU headless *(legacy)* |

**Cloud Hypervisor networking** (requires one-time TAP setup):

```bash
sudo nix run .#setup-cloud-hypervisor-network   # creates TAP with NAT
nix run .#run-redox-cloud-hypervisor-net         # boot with virtio-net
```

**Environment variables:** `CH_CPUS`, `CH_MEMORY`, `CH_HUGEPAGES`, `CH_DIRECT_IO`

**Exit:** Cloud Hypervisor `Ctrl+C` · QEMU headless `Ctrl+A X` · QEMU graphical: close window

## Building

```bash
# Host tools (native)
nix build .#cookbook .#redoxfs .#installer

# Cross-compiled to x86_64-unknown-redox
nix build .#relibc .#kernel .#bootloader .#base
nix build .#ion .#helix .#ripgrep .#bat  # ... and more

# Disk images (via module system profiles)
nix build .#redox-default     # development (auto networking, CLI tools)
nix build .#redox-minimal     # ion + uutils only, no network
nix build .#redox-graphical   # Orbital desktop + audio
nix build .#redox-cloud       # Cloud Hypervisor optimized (static IP, virtio-only)
```

## Module System

Disk images are built through a declarative module system powered by
**[adios](https://github.com/adisbladis/adios)** (by
[@adisbladis](https://github.com/adisbladis)) with
**[Korora](https://github.com/adisbladis/adios)** types. Both are vendored
in `nix/vendor/` with no nixpkgs dependency in the evaluator.

Unlike NixOS's `lib.evalModules`, adios modules declare **explicit inputs** by
path — no global `config` namespace, no `lib.mkOption`/`lib.mkIf` machinery.
Each module is a self-contained unit with typed options and named dependencies.

### Module Tree

```
/pkgs          — Package injection (pkgs, hostPkgs, nixpkgsLib)
/boot          — Kernel, bootloader, initfs config
/hardware      — Driver selection (enum-typed)
/networking    — Network mode, DNS, interfaces
/environment   — Packages, shell aliases, variables
/filesystem    — Directory layout, symlinks
/graphics      — Orbital desktop config
/services      — Init scripts, startup
/users         — User accounts (struct-typed), groups
/build         — Produces rootTree, initfs, diskImage (inputs: all above)
```

### Korora Type System

All options use Korora's compound types — configuration errors are caught at
Nix evaluation time with precise messages:

```nix
# Structs — typed records with required and optional fields
struct "User" {
  uid = int; gid = int; home = string; shell = string; password = string;
  realname = optionalAttr string;   # absent is ok, wrong type is not
  createHome = optionalAttr bool;
}

# Enums — closed sets of valid values
enum "StorageDriver" [ "ahcid" "nvmed" "ided" "virtio-blkd" ]
enum "NetworkMode"   [ "auto" "dhcp" "static" "none" ]

# Parameterized containers
listOf (enum "GraphicsDriver" [ "virtio-gpud" "bgad" ])
attrsOf (struct "Interface" { address = string; gateway = string; })
listOf derivation    # system packages
attrsOf string       # environment variables, shell aliases
```

### Profiles

Pre-built option presets — not NixOS modules, just attrsets of overrides:

| Profile | Description |
|---|---|
| `development` | CLI tools, auto networking, remote shell on port 8023 |
| `minimal` | Ion + uutils, no networking, no extras |
| `graphical` | Orbital desktop, audio drivers, USB, full CLI |
| `cloud-hypervisor` | Static IP, virtio-only drivers, optimized for CH |

### Custom Configuration

```nix
redoxSystem {
  profiles = [ "development" ];
  overrides = {
    "/users" = {
      users.admin = {
        uid = 1001; gid = 1001;
        home = "/home/admin"; shell = "/bin/ion"; password = "redox";
      };
    };
    "/networking" = {
      mode = "static";  # type-checked: must be auto|dhcp|static|none
      interfaces.eth0 = { address = "10.0.0.5"; gateway = "10.0.0.1"; };
    };
    "/environment" = {
      systemPackages = [ pkgs.helix pkgs.ripgrep ];
      shellAliases = { ll = "ls -la"; };
    };
  };
  pkgs = redoxPackages;
  hostPkgs = nixpkgs;
}
```

See `nix/redox-system/examples/configuration.nix` for a complete example.

## Architecture

### Build Pipeline

```
relibc (C library)
  └─► kernel, bootloader, base, ion, uutils, ...
        └─► initfs (initial RAM filesystem)
              └─► diskImage (bootable UEFI image)
                    └─► run-redox (Cloud Hypervisor / QEMU)
```

### Cross-Compilation

All Redox packages cross-compile to `x86_64-unknown-redox` using:

- LLVM/Clang toolchain with `ld.lld`
- Rust with `-Z build-std` (builds std from source)
- Offline Cargo vendoring with version-aware sysroot merging

### Directory Structure

```
flake.nix
nix/
├── flake-modules/         # Flake-parts modules (packages, apps, system, devshells)
├── lib/                   # Build helpers (rust flags, sysroot, vendoring, stub libs)
├── pkgs/
│   ├── host/              # Native tools (cookbook, redoxfs, installer)
│   ├── system/            # Core OS (relibc, kernel, bootloader, base)
│   ├── userspace/         # User programs (ion, helix, ripgrep, ...)
│   └── infrastructure/    # VM runners
├── redox-system/          # Adios module system
│   ├── default.nix        # redoxSystem entry point
│   ├── lib.nix            # Redox helpers (passwd/group format)
│   ├── modules/           # 10 adios modules (auto-imported)
│   │   └── build/         # Consolidated build module
│   ├── profiles/          # Option presets
│   └── examples/          # Example configurations
├── vendor/
│   ├── adios/             # Module system (github.com/adisbladis/adios)
│   └── korora/            # Type system
└── patches/               # Source patches
```

## Testing

```bash
# Automated boot test (verifies system boots to shell prompt)
nix run .#boot-test

# Functional test (boots VM, runs ~40 in-guest tests, reports results)
nix run .#functional-test

# Module system tests (fast, no cross-compilation)
nix build .#checks.x86_64-linux.eval-profile-default  # profile evaluates
nix build .#checks.x86_64-linux.type-valid-user-complete  # type checking
nix build .#checks.x86_64-linux.artifact-rootTree-has-passwd  # build output
```

The functional test suite builds a test-enabled disk image with a modified
startup script. Instead of launching an interactive shell, it runs an Ion
test suite that validates: shell fundamentals, system identity, filesystem
operations, config file presence, CLI tool availability, and device files.
Results are written to serial as structured `FUNC_TEST:name:PASS/FAIL` lines
parsed by the host-side runner.

## Development

```bash
nix develop            # full dev environment
nix develop .#minimal  # quick iteration
nix develop .#native   # everything including legacy tools
```

## Credits

- **[Redox OS](https://www.redox-os.org/)** — the operating system itself
- **[adios](https://github.com/adisbladis/adios)** by [@adisbladis](https://github.com/adisbladis) — module system and Korora type system, vendored in `nix/vendor/`
- **[Nix](https://nixos.org/)** — the build system making this reproducible

## License

Redox OS components are licensed under their respective upstream licenses (MIT).
