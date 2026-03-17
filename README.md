# Redox OS — Built with Nix

A complete [Redox OS](https://www.redox-os.org/) built entirely from source
using Nix. One command gets you a running Redox desktop.

## Run It

```bash
nix run github:brittonr/redox
```

That builds everything from source and boots a graphical Redox VM in QEMU.
Login: `user` / `redox` (or `root` / `redox`).

First build takes a while (cross-compiling the full OS). Subsequent runs
use cached artifacts.

### Other ways to run

```bash
nix run .#graphical     # Graphical desktop (QEMU + GTK) — the default
nix run .#headless      # Serial console only (Cloud Hypervisor, faster)
nix run .#run-redox-minimal      # Bare minimum: ion shell + uutils
nix run .#run-redox-self-hosting # With Rust toolchain for on-guest compilation
```

**Exit:** Close the QEMU window (graphical) · `Ctrl+C` (headless) · `Ctrl+A X` (QEMU headless)

### Build the disk image

```bash
nix build              # Graphical disk image (default)
nix build .#diskImage  # Development image (no graphics)
```

The image is a GPT disk with a UEFI boot partition and RedoxFS root filesystem.

## What's in the Image

| Category | Packages |
|---|---|
| **Boot** | bootloader, kernel, initfs |
| **System** | 46 base daemons/drivers, relibc (C library) |
| **Shell** | ion (default), bash |
| **Coreutils** | uutils, binutils, extrautils, findutils |
| **Editors** | helix, sodium, smith |
| **Network** | smolnetd (TCP/IP stack), dhcpd, ping, nc, curl |
| **CLI Tools** | ripgrep, fd, bat, hexyl, zoxide, dust, lsd, bottom, tokei |
| **Dev Tools** | gnu-make, git, diffutils, sed, patch, strace |
| **Package Manager** | snix (Nix evaluator + builder running on Redox) |
| **Graphics** | orbital, orbterm, orbutils, orbdata *(graphical image)* |
| **Self-Hosting** | rustc, cargo, LLVM/LLD, cmake *(self-hosting image only)* |

## How It Works

Every component is a Nix derivation built from source — no binary blobs, no
upstream Makefile/cookbook. The build has three layers:

1. **Bootstrap** — relibc (14 patches), kernel, bootloader. Cross-compiled
   with `-Z build-std` since they ARE the standard library.

2. **Userspace** — 70+ packages. Rust crates are split into per-crate
   derivations via [unit2nix](https://github.com/brittonr/unit2nix) for
   granular caching. C libraries use a clang cross-compiler with relibc
   as the sysroot.

3. **Assembly** — A NixOS-style module system (17 modules) evaluates the
   config and produces the root tree, initfs, and bootable disk image.

### NixOS-style Configuration

Profiles are declarative, composable Nix expressions:

```nix
# profiles/my-server.nix
{ pkgs, lib }:
{
  "/environment" = {
    systemPackages = [ pkgs.ion pkgs.uutils pkgs.extrautils pkgs.snix pkgs.redox-curl ];
    etc."etc/motd" = { text = "Welcome to my Redox server!"; };
  };

  "/networking" = {
    enable = true;
    mode = "dhcp";
    dns = [ "1.1.1.1" "8.8.8.8" ];
    remoteShellEnable = true;
  };

  "/users".users.admin = {
    uid = 1001; gid = 1001;
    home = "/home/admin";
    shell = "/bin/ion";
    password = "changeme";
    createHome = true;
  };

  "/services".ssh = {
    enable = true;
    port = 22;
    permitRootLogin = false;
  };

  "/security".requirePasswords = true;
  "/time".hostname = "my-server";
}
```

Profiles compose with `//` — the graphical profile extends the development
profile, which extends the base.

### System Management (on-guest)

Once booted, `snix` manages the running system like `nixos-rebuild`:

```bash
snix system rebuild          # Apply configuration.nix changes
snix system rebuild --dry-run
snix system generations      # List system generations
snix system switch --rollback # Roll back to previous state
snix system gc               # Garbage collect old generations
snix install ripgrep         # Install a package from the binary cache
```

## Testing

```bash
nix run .#functional-test          # 152 in-guest tests
nix run .#self-hosting-test        # 66 compilation tests
nix run .#rebuild-generations-test # 25 rebuild/rollback tests
nix run .#e2e-rebuild-test         # 17 full activate pipeline tests
nix run .#network-test             # 9 connectivity tests
nix run .#bridge-test              # 45 virtio-fs package delivery tests
nix flake check                    # 163 Nix-level module system checks
```

## Build Bridge

Push packages from the host to a running VM without rebuilding disk images:

```bash
nix run .#run-redox-shared                    # Boot VM with shared filesystem
nix run .#push-to-redox -- ripgrep fd bat     # Push from host
# Inside guest:
snix install ripgrep
```

## Self-Hosting

The self-hosting image includes a full Rust toolchain cross-compiled for Redox:

```bash
nix run .#run-redox-self-hosting
# Inside guest:
mkdir hello && cd hello
cargo init
cargo build    # compiles natively on Redox
```

`snix build .#ripgrep` works — Nix derivation evaluation and building, on Redox.

## Requirements

- Nix with flakes enabled
- KVM support (for VM acceleration)
- ~10 GB disk space for a full build
- GTK for graphical mode (headless works without)

## Structure

```
flake.nix                  Entry point
nix/
  flake-modules/           Flake outputs (packages, apps, checks)
  pkgs/system/             Core: relibc, kernel, bootloader, base (46 daemons)
  pkgs/userspace/          70+ packages: ion, helix, ripgrep, snix, rustc, ...
  pkgs/infrastructure/     VM runners, test harnesses, build bridge
  redox-system/
    modules/               17 NixOS-style modules (environment, networking, ...)
    profiles/              Preset configurations (minimal, development, graphical, ...)
snix-redox/                snix source (Nix evaluator/builder for Redox)
```

## Credits

- **[Redox OS](https://www.redox-os.org/)** — the operating system
- **[adios](https://github.com/adisbladis/adios)** — module system
- **[snix](https://snix.dev/)** — Nix evaluator (patched for Redox)
