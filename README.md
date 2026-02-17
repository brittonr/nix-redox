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

# Disk images
nix build .#diskImage                 # headless (auto network)
nix build .#diskImageCloudHypervisor  # static networking for TAP
nix build .#diskImageGraphical        # with Orbital desktop
```

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
