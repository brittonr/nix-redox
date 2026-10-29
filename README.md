# Redox OS — Built with Nix

A complete [Redox OS](https://www.redox-os.org/) built entirely from source
using Nix. One command gets you a running Redox desktop.

## Alpha Status

This tree is being prepared as an alpha-quality Redox/Nix distribution:
the VM build/run path, declarative system assembly, on-guest `snix` workflows,
and self-hosting proofs are in scope; bare-metal board support and some
networking paths remain experimental. See `docs/alpha-release.md` for the
release gate, evidence rules, and known limitations.

## Run It

```bash
nix run github:brittonr/redox
```

That builds everything from source and boots a graphical Redox VM in QEMU.
Login: `user` / `redox` (or `root` / `redox`).

First build takes a while (cross-compiling the full OS). Subsequent runs
use cached artifacts.

From a local checkout, run `nix run .`. The graphical launcher requires an
`x86_64-linux` host with access to `/dev/kvm` and an X11 or Wayland display.
Use `nix run .#headless` when no graphical display is available.

To use `nix run redox` from any directory, register this checkout once:

```bash
nix registry add redox "git+file://$PWD"
nix run redox
```

The alias follows this local checkout, including tracked working-tree changes.

### Other ways to run

```bash
nix run .#graphical     # Graphical desktop (QEMU + GTK) — the default
nix run .#headless      # Serial console only (Cloud Hypervisor, faster)
nix run .#run-redox-minimal      # Bare minimum: ion shell + uutils
nix run .#run-redox-self-hosting # With Rust toolchain for on-guest compilation
```

**Exit:** Close the QEMU window (graphical) · `Ctrl+C` (headless) · `Ctrl+A X` (QEMU headless)

Cloud Hypervisor runners default to buffered disk I/O. `CH_DIRECT_IO=on`
remains an opt-in override, but prevented the pinned firmware from finding
the bootable disk in the verified run; leave it unset for normal boots.

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

External system-layer consumers should target the public substrate surface at
`legacyPackages.${system}.redoxSubstrate`, not private flake-module internals or
Adios path-keyed profiles. See `docs/redox-substrate.md` for the manifest,
primitive plan shape, builder shell, and Redox/OnixOS boundary.

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

Use tiered release gates for normal validation:

```bash
nix run .#test-quick  # module eval, type, artifact, and library checks
nix run .#test-host   # quick tier plus host tools and snix host tests
nix run .#test-cross  # host tier plus cross-compiled Redox packages
nix run .#test-vm     # fast VM integration tier: boot, functional, schemes, bridge
```

Focused VM suites remain available when touching their subsystem:

```bash
nix run .#functional-test
nix run .#bridge-test
nix run .#rebuild-generations-test
nix run .#e2e-rebuild-test
nix run .#network-test
nix run .#snix-sandbox-test -- --verbose
nix run .#self-hosting-test -- --verbose
```

Run `nix flake check` as the final aggregate gate for a release candidate.
See `docs/alpha-release.md` for the full alpha checklist and proof-artifact
rules.

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

### Native system rebuilds

`systemSource` selects a guest-local system derivation instead of the Linux
build bridge. In a self-hosting image, stage `native-system-source-bundle` at
`/usr/src/nix-redox` and `native-kernel-rebuild-bundle` at
`/usr/src/native-kernel-rebuild`. Both bundles are flake package outputs.

```nix
# /etc/redox-system/configuration.nix
{
  systemSource = "/usr/src/nix-redox/build.nix";
  hostname = "native-redox";
  hardware.networkDrivers = [ ];
}
```

Run `snix system rebuild` normally. `systemSource` also applies to `--local`
and `--source`; `packageSources` remains available for native package
derivations. The source expression accepts `{ config, currentManifest }` and
returns a derivation containing `manifest.json`, boot artifacts, an etc source,
and optional `root-files` for mutable rootfs files.

The staged graph builds the kernel, UEFI bootloader, initfs archive tools,
initfs, etc tree, and generation identity on Redox, offline. Existing packages
provide the bootstrap/toolchain; source packages join the same dependency graph.
Initfs, PCI configuration, and init units reuse the host system renderers.
Newly imported literal-path and `builtins.toFile` inputs are materialized in
`/nix/store` before native builders run. Publication preserves file contents,
executability, and symlinks, and registers source metadata for store references.
Dry runs evaluate the graph without publishing those imported inputs.
Evaluation failures report the innermost Nix source diagnostic instead of
repeatedly dumping the generated manifest expression as trace frames.

Only a successful graph build reaches activation. Generations retain their
boot/identity/etc GC roots and original init-unit contents for rollback.

The focused acceptance image exercises offline native rebuild, failed-build
isolation, then three firmware boots on one disk: seed → native → exact previous
generation.

```bash
TMPDIR=/var/tmp nix run .#native-rebuild-test -- --verbose
```

The host harness installs the selected EFI bytes extracted from that guest disk
into its ESP before each restart; this is not a production guest ESP installer.
Executing bootloader/kernel/initfs identities must match the selected generation
after both restarts. Rollback checks restored configuration, service units, boot
bytes, and native GC roots. Captures retain all three boot logs and identities;
see [`docs/self-hosting/proof-artifacts.md`](docs/self-hosting/proof-artifacts.md).


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
