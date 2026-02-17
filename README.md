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

### Apps

| Command | Description |
|---|---|
| `nix run .#run-redox` | Cloud Hypervisor, headless with serial console *(default)* |
| `nix run .#run-redox-graphical` | QEMU with GTK graphical display |
| `nix run .#run-redox-qemu` | QEMU headless *(legacy)* |
| `nix run .#run-redox-graphical-drivers` | Graphical image, headless *(test graphics drivers)* |

**Cloud Hypervisor networking** (requires one-time TAP setup):

```bash
sudo nix run .#setup-cloud-hypervisor-network   # creates TAP with NAT
nix run .#run-redox-cloud-hypervisor-net         # boot with virtio-net
```

**Cloud Hypervisor dev mode** (API socket for runtime control):

```bash
nix run .#run-redox-cloud-hypervisor-dev   # boot with API socket
nix run .#pause-redox                      # pause VM
nix run .#resume-redox                     # resume VM
nix run .#snapshot-redox                   # snapshot VM
nix run .#info-redox                       # show VM info
nix run .#resize-memory-redox              # resize VM memory
```

### Environment Variables

Cloud Hypervisor runners accept:

- `CH_CPUS` — number of vCPUs (default: 4)
- `CH_MEMORY` — memory size (default: 2048M)
- `CH_HUGEPAGES` — enable huge pages
- `CH_DIRECT_IO` — enable direct I/O for disk

### Exit

- **Cloud Hypervisor**: `Ctrl+C`
- **QEMU headless**: `Ctrl+A` then `X`
- **QEMU graphical**: close the window

## Building Individual Packages

```bash
# Host tools (fast, native builds)
nix build .#cookbook        # package manager
nix build .#redoxfs        # filesystem tools
nix build .#installer      # system installer

# System components (cross-compiled to x86_64-unknown-redox)
nix build .#relibc         # C library
nix build .#kernel         # kernel
nix build .#bootloader     # UEFI bootloader
nix build .#base           # init, drivers, daemons

# Userspace
nix build .#ion            # shell
nix build .#helix          # editor
nix build .#ripgrep        # search
nix build .#bat            # cat with highlighting
# ... and more (see: nix flake show)

# Disk images (via module system profiles)
nix build .#redox-default             # development profile (auto network)
nix build .#redox-cloud               # cloud profile (static networking for TAP)
nix build .#redox-graphical           # graphical profile (Orbital desktop)
nix build .#diskImage                 # alias for redox-default
```

## Module System (NixOS-style Profiles)

All disk images and runners are built through a NixOS-style module system.
Pre-built profiles provide ready-to-use configurations:

| Command | Profile | Description |
|---|---|---|
| `nix build .#redox-default` | Development | CLI tools, auto networking, remote shell |
| `nix build .#redox-minimal` | Minimal | Ion + uutils only, no network |
| `nix build .#redox-graphical` | Graphical | Orbital desktop, audio, full CLI |
| `nix build .#redox-cloud` | Cloud | Static IP, virtio-only drivers |

Each profile has matching runners:

```bash
nix run .#run-redox-default           # Development in Cloud Hypervisor
nix run .#run-redox-default-qemu      # Development in QEMU
nix run .#run-redox-minimal           # Minimal in Cloud Hypervisor
nix run .#run-redox-cloud             # Cloud profile headless
nix run .#run-redox-cloud-net         # Cloud profile with TAP networking
nix run .#run-redox-graphical-desktop # Graphical with QEMU GTK display
nix run .#run-redox-graphical-headless # Graphical headless (test drivers)
```

### Custom Configurations

Create your own system by writing a NixOS-style module:

```nix
# my-system.nix
{ config, lib, pkgs, ... }:
{
  imports = [ ./nix/redox-system/modules/profiles/development.nix ];

  redox.users.users.admin = {
    uid = 1001; gid = 1001;
    home = "/home/admin";
    shell = "/bin/ion";
  };

  redox.networking.mode = "static";
  redox.networking.interfaces.eth0 = {
    address = "10.0.0.5";
    gateway = "10.0.0.1";
  };

  redox.environment.systemPackages = with pkgs;
    [ ripgrep fd bat ];

  redox.environment.shellAliases.ll = "ls -la";
}
```

Build it via the `mkRedoxSystem` helper exposed in `legacyPackages`:

```bash
nix eval .#legacyPackages.x86_64-linux.mkRedoxSystem
```

See `nix/redox-system/examples/configuration.nix` for a complete example.

## Development

```bash
nix develop            # full dev environment (recommended)
nix develop .#minimal  # minimal, for quick iteration
nix develop .#native   # everything including legacy tools

nix fmt                # format all code
nix flake check        # run all checks (eval, builds, boot test)
```

## Architecture

### Build Pipeline

Components build in dependency order:

```
relibc (C library)
  └─► kernel, bootloader, base, ion, uutils, ...
        └─► initfs (initial RAM filesystem)
              └─► diskImage (bootable UEFI image)
                    └─► run-redox (Cloud Hypervisor / QEMU runner)
```

### Cross-Compilation

All Redox target packages cross-compile to `x86_64-unknown-redox` using:

- LLVM/Clang toolchain with `ld.lld`
- Rust with `-Z build-std` (builds std from source)
- Offline Cargo vendoring with version-aware sysroot merging

### Flake Structure

```
flake.nix                          # inputs and top-level wiring
nix/
├── flake-modules/
│   ├── packages.nix               # all package exports
│   ├── apps.nix                   # runnable apps
│   ├── system.nix                  # module system integration (disk images, runners)
│   ├── devshells.nix              # development shells
│   ├── checks.nix                 # CI checks
│   ├── toolchain.nix              # Rust toolchain setup
│   ├── sources.nix                # patched source inputs
│   ├── overlays.nix               # nixpkgs overlay
│   ├── nixos-module.nix           # NixOS integration module
│   ├── flake-modules.nix          # composable flake-parts modules
│   ├── treefmt.nix                # code formatting
│   └── git-hooks.nix              # pre-commit hooks
├── lib/
│   ├── rust-flags.nix             # centralized RUSTFLAGS/CC config
│   ├── sysroot.nix                # Rust sysroot vendor merging
│   ├── vendor.nix                 # Cargo vendor helpers
│   └── stub-libs.nix              # unwinding stubs for panic=abort
├── pkgs/
│   ├── host/                      # native tools (cookbook, redoxfs, installer)
│   ├── system/                    # core OS (relibc, kernel, bootloader, base)
│   ├── userspace/                 # user programs (ion, helix, ripgrep, ...)
│   └── infrastructure/            # initfs, disk image, VM runners
├── redox-system/                   # NixOS-style module system
│   ├── default.nix                 # redoxSystem entry point
│   ├── eval.nix                    # module evaluator
│   ├── lib.nix                     # Redox-specific helpers
│   ├── module-list.nix             # base module list
│   ├── modules/
│   │   ├── config/                 # option modules (boot, users, networking, ...)
│   │   ├── build/                  # build modules (initfs, disk-image, toplevel)
│   │   ├── profiles/               # pre-built profiles (minimal, dev, graphical, cloud)
│   │   └── system/                 # activation and setup
│   └── examples/                   # example configurations
└── patches/                       # source patches
```

### Integration

This flake exports overlays, a NixOS module, and composable flake-parts modules
for use in other projects:

```nix
# NixOS module
{
  imports = [ redox.nixosModules.default ];
  programs.redox.enable = true;
}

# Overlay
{ overlays = [ redox.overlays.default ]; }

# Flake-parts modules (pick what you need)
{ imports = [ redox.flakeModules.packages ]; }
```

## License

Redox OS components are licensed under their respective upstream licenses (MIT).
