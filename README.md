# RedoxOS — Pure Nix Build

A complete, reproducible build system for [Redox OS](https://www.redox-os.org/)
using Nix flakes. Every component from relibc through the bootable disk image
is built hermetically. Includes **snix**, a Nix evaluator and package builder
that runs natively on Redox, enabling self-hosted compilation.

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
low overhead. Graphical mode uses QEMU for better input device support.

## What's in the Image

GPT disk with a UEFI boot partition and RedoxFS root filesystem:

| Category | Packages |
|---|---|
| **Boot** | bootloader, kernel, initfs |
| **System** | base (init, drivers, daemons), relibc |
| **Shell** | ion (default), bash |
| **Coreutils** | uutils (Rust coreutils), binutils, extrautils, findutils |
| **Editors** | helix, sodium, smith |
| **Network** | netutils (dhcpd, dnsd, ping, ifconfig, nc), curl |
| **CLI Tools** | ripgrep, fd, bat, hexyl, zoxide, dust, lsd, bottom, tokei, shellharden |
| **User Mgmt** | userutils (getty, login, passwd, su, sudo) |
| **Dev Tools** | gnu-make, git, diffutils, sed, patch, strace |
| **Nix** | snix (eval, build, install, store/profile management) |
| **Self-Hosting** | rustc, cargo, lld, llvm-ar, cmake *(self-hosting image only)* |
| **Graphics** | orbital, orbterm, orbutils, orbdata *(graphical image only)* |

## Running

| Command | Description |
|---|---|
| `nix run .#run-redox` | Cloud Hypervisor, headless with serial console |
| `nix run .#run-redox-graphical` | QEMU with GTK graphical display |
| `nix run .#run-redox-qemu` | QEMU headless (legacy) |
| `nix run .#run-redox-minimal` | Minimal image (ion + uutils only) |
| `nix run .#run-redox-shared` | With virtio-fs shared directory for build bridge |
| `nix run .#run-redox-self-hosting` | Self-hosting image with full toolchain |

**Cloud Hypervisor networking** (one-time TAP setup):

```bash
sudo nix run .#setup-cloud-hypervisor-network
nix run .#run-redox-cloud-net
```

**Environment variables:** `CH_CPUS`, `CH_MEMORY`, `CH_HUGEPAGES`, `CH_DIRECT_IO`

**Exit:** Cloud Hypervisor `Ctrl+C` · QEMU headless `Ctrl+A X` · QEMU graphical: close window

### redox-rebuild

System configuration manager (like `nixos-rebuild`):

```bash
nix run .#redox-rebuild -- build              # Build default profile
nix run .#redox-rebuild -- build graphical    # Build graphical profile
nix run .#redox-rebuild -- run                # Build + launch VM
nix run .#redox-rebuild -- test               # Build + automated boot test
nix run .#redox-rebuild -- diff               # Show what changed
nix run .#redox-rebuild -- list-generations   # Build history
nix run .#redox-rebuild -- rollback           # Switch to previous generation
```

## Building

```bash
# Host tools (native)
nix build .#cookbook .#redoxfs .#installer

# Cross-compiled to x86_64-unknown-redox
nix build .#relibc .#kernel .#bootloader .#base
nix build .#ion .#helix .#ripgrep .#bat .#redox-bash .#redox-curl
nix build .#snix                # Nix evaluator/builder for Redox
nix build .#redox-rustc         # Full Rust toolchain for Redox

# C libraries
nix build .#redox-zlib .#redox-openssl .#redox-ncurses .#redox-readline
nix build .#redox-freetype2 .#redox-fontconfig .#redox-harfbuzz

# Disk images (via module system profiles)
nix build .#redox-default       # Development (auto networking, CLI tools)
nix build .#redox-minimal       # Ion + uutils only, no network
nix build .#redox-graphical     # Orbital desktop + audio
nix build .#redox-cloud         # Cloud Hypervisor optimized
nix build .#redox-self-hosting  # Full Rust toolchain + snix
```

## Module System

Disk images are built through a declarative module system powered by
**[adios](https://github.com/adisbladis/adios)** with
**[Korora](https://github.com/adisbladis/adios)** types (both vendored in
`nix/vendor/`, no nixpkgs dependency in the evaluator).

Unlike NixOS's `lib.evalModules`, adios modules declare **explicit inputs** by
path — no global `config` namespace, no `lib.mkOption`/`lib.mkIf` machinery.

### Module Tree (17 modules)

```
/pkgs              Package injection (pkgs, hostPkgs, nixpkgsLib)
/boot              Kernel, bootloader, initfs config
/hardware          Driver selection (enum-typed)
/networking        Network mode, DNS, interfaces
/environment       Packages, shell aliases, variables
/filesystem        Directory layout, symlinks
/graphics          Orbital desktop config
/services          Init scripts, startup
/users             User accounts (struct-typed), groups
/security          Namespace access, setuid, policies
/time              Hostname, timezone, NTP
/programs          Ion, helix, editor, httpd config
/logging           Log levels, destinations, retention
/power             ACPI, power/idle actions, panic behavior
/snix              stored/profiled daemons, build sandboxing
/virtualisation    VM-specific config (virtio, shared fs)
/build             Produces rootTree, initfs, diskImage (inputs: all above)
```

### Type System

All options use Korora's compound types — errors caught at eval time:

```nix
struct "User" { uid = int; gid = int; home = string; shell = string; }
enum "NetworkMode" [ "auto" "dhcp" "static" "none" ]
listOf (enum "StorageDriver" [ "ahcid" "nvmed" "virtio-blkd" ])
attrsOf (struct "Interface" { address = string; gateway = string; })
```

### Custom Configuration

```nix
redoxSystem {
  profiles = [ "development" ];
  overrides = {
    "/users".users.admin = {
      uid = 1001; gid = 1001;
      home = "/home/admin"; shell = "/bin/ion"; password = "redox";
    };
    "/networking" = {
      mode = "static";
      interfaces.eth0 = { address = "10.0.0.5"; gateway = "10.0.0.1"; };
    };
    "/environment".systemPackages = [ pkgs.helix pkgs.ripgrep ];
  };
}
```

### Profiles

| Profile | Description |
|---|---|
| `development` | CLI tools, auto networking, serial console, 48 packages |
| `minimal` | Ion + uutils, no networking |
| `graphical` | Orbital desktop, audio, USB, full CLI |
| `cloud-hypervisor` | Static IP, virtio-only drivers |
| `self-hosting` | Full Rust toolchain + snix + LLVM |
| `scheme-native` | stored + profiled scheme daemons enabled |

## snix — Nix on Redox

**snix** is a Nix evaluator and package builder that runs natively on Redox OS.
It uses snix-eval (a bytecode VM) for Nix expression evaluation and implements
store path computation, NAR serialization, and sandboxed local builds.

### What works

- **Eval**: Full Nix language including `derivationStrict`, `builtins.fetchurl`,
  `builtins.fetchTarball`, `import`, `builtins.toJSON`, string interpolation
- **Build**: Local builds with per-path filesystem proxy sandbox — evaluate a
  derivation, compute store paths, run the builder, register outputs in PathInfoDb
- **Install**: From local binary cache or remote HTTP/HTTPS cache
- **Flake installables**: `snix build .#ripgrep` — resolve flake.lock, fetch inputs,
  evaluate, build
- **Store management**: list, info, closure, GC, roots, verify
- **System management**: generations, switch, rollback, upgrade, rebuild
- **Scheme daemons**: `stored` (serves `/nix/store/` via `store:` scheme) and
  `profiled` (union profile views via `profile:` scheme)

### Usage inside Redox

```bash
# Install from binary cache
snix install ripgrep
snix install ripgrep --cache-url http://10.0.2.2:18080

# Build a Nix expression
snix build --expr 'derivation { name = "hello"; builder = "/bin/bash"; ... }'
snix build --file ./hello.nix

# Build from a flake
snix build .#ripgrep

# Evaluate Nix expressions
snix eval --expr '1 + 1'
snix eval --expr 'builtins.map (x: x * 2) [1 2 3]'

# Store management
snix store list
snix store gc --dry-run
snix system generations
snix system rebuild
```

### Scheme Daemons

When the `scheme-native` profile is active, two daemons integrate snix with
Redox's namespace architecture:

- **`stored`** — Serves `/nix/store/` paths via the `store:` scheme. Packages
  register at install time but files are served lazily on first access.
- **`profiled`** — Presents union views of installed packages via the `profile:`
  scheme. Add/remove updates an in-memory mapping and persists atomically.

Both daemons start automatically via init scripts and handle live package
installation — install a package while daemons are running and the new content
appears immediately.

## Self-Hosting

The self-hosting image includes a complete Rust toolchain cross-compiled for
Redox: `rustc` (with `librustc_driver.so`), `cargo`, `lld`, `llvm-ar`, and
`cmake`. Enough to compile Rust programs natively on Redox.

### What works

- `rustc` compiles Rust source to ELF binaries
- `cargo build` with dependencies, workspaces, proc-macros, build scripts
- Proc-macro `.so` files load correctly through `ld_so`
- Parallel compilation at JOBS=2 (fork-lock + lld-wrapper fixes)
- `snix build .#ripgrep` — 33 crates compiled at JOBS=2
- snix compiles itself (168 crates at JOBS=2)
- Per-path filesystem proxy sandbox enforces declared build inputs

### Test suite

66 self-hosting tests covering toolchain presence, compilation, linking,
proc-macros, build scripts, cargo workflows, and snix self-compilation.

## Build Bridge

Live package delivery from the host to a running Redox VM via virtio-fs,
without rebuilding disk images.

```
Host                                    Guest (Redox VM)
──────────────────                      ──────────────────
nix build .#ripgrep                     /scheme/shared/cache/
  → NAR serialize + zstd compress         ├── packages.json
  → write to shared cache                 ├── *.narinfo
                                          └── *.nar.zst
virtiofsd (FUSE over virtqueue)         virtio-fsd driver
  ↕                                       → /scheme/shared/
Cloud Hypervisor --fs tag=shared        snix install ripgrep
                                          → reads cache, unpacks
```

### Usage

```bash
# Boot VM with shared filesystem
nix run .#run-redox-shared

# Push packages from host
nix run .#push-to-redox -- ripgrep
nix run .#push-to-redox -- ripgrep fd bat    # multiple
nix run .#push-to-redox -- --all             # all available
nix run .#push-to-redox -- --list            # show available

# Inside guest
export SNIX_CACHE_PATH=/scheme/shared/cache
snix install ripgrep

# Host-side daemon for in-guest rebuild requests
nix run .#build-bridge
```

### Network Binary Cache

Packages can also be installed over HTTP from a remote binary cache server:

```bash
# Inside Redox (with networking enabled)
snix install ripgrep --cache-url http://10.0.2.2:18080
```

QEMU SLiRP networking routes `10.0.2.2` to the host. Guest gets DHCP
automatically with the development profile.

## Testing

```bash
# Automated boot test (verifies boot milestones on serial)
nix run .#boot-test

# Functional test (boots VM, runs 152 in-guest tests)
nix run .#functional-test

# Self-hosting test (boots VM, runs 66 compilation tests)
nix run .#self-hosting-test

# Scheme-native test (boots VM, tests stored + profiled daemons, 22 tests)
nix run .#scheme-native-test

# Network test (boots VM with QEMU SLiRP, tests HTTP install, 9 tests)
nix run .#network-test

# Bridge test (pushes packages via virtio-fs, tests snix install, 45 tests)
nix run .#bridge-test

# Module system checks (fast, no cross-compilation)
nix build .#checks.x86_64-linux.eval-profile-default
nix build .#checks.x86_64-linux.type-valid-user-complete
nix build .#checks.x86_64-linux.artifact-rootTree-has-passwd

# All 163 nix checks
nix flake check
```

### Test counts

| Suite | Tests | What it covers |
|---|---|---|
| Host unit tests | 504 | snix internals: eval, store, pathinfo, install, build, activate, cache, flake |
| Nix eval checks | 163 | Module system: profiles, types, assertions, artifacts |
| Functional VM | 152 | In-guest: shell, filesystem, config, CLI tools, env propagation, snix eval/build |
| Self-hosting VM | 66 | Toolchain: rustc, cargo, proc-macros, build scripts, snix self-compile |
| Scheme-native VM | 22 | Daemon lifecycle: stored, profiled, live install, .control mutations |
| Network VM | 9 | DHCP, connectivity, HTTP cache search/install/execute |
| Bridge VM | 45 | virtio-fs: push, search, install, remove, live push, reinstall |

## Architecture

### Build Pipeline

```
relibc (C library)
  ├── C libraries (zlib, openssl, ncurses, readline, freetype2, ...)
  ├── kernel, bootloader, base (init, drivers, daemons)
  ├── Rust packages (ion, helix, ripgrep, snix, ...)
  ├── C programs (bash, curl, git, gnu-make, cmake, ...)
  └── LLVM + rustc + cargo (self-hosting toolchain)
        └── initfs → diskImage → run-redox (Cloud Hypervisor / QEMU)
```

### Cross-Compilation

Target: `x86_64-unknown-redox`. Toolchain: LLVM/Clang with `ld.lld`.
Rust packages use the toolchain's pre-compiled rlibs (no `-Z build-std`
needed for userspace). Kernel and bootloader still use `-Z build-std`
for their custom target triples.

### Directory Structure

```
flake.nix
nix/
├── flake-modules/         Flake module system (packages, apps, system, devshells)
├── lib/                   Build helpers (rust flags, sysroot, vendoring, stub libs)
├── pkgs/
│   ├── host/              Native tools (cookbook, redoxfs, installer)
│   ├── system/            Core OS (relibc, kernel, bootloader, base, virtio-fsd)
│   ├── userspace/         User programs (ion, helix, ripgrep, snix, rustc, ...)
│   └── infrastructure/    VM runners, test harnesses, build bridge
├── redox-system/          Adios module system
│   ├── default.nix        redoxSystem entry point with .extend chaining
│   ├── lib.nix            Redox helpers (passwd/group format, Argon2 hashing)
│   ├── modules/           17 adios modules (auto-imported)
│   ├── profiles/          Option presets + test profiles
│   └── examples/          Example configurations
├── vendor/
│   ├── adios/             Module system (github.com/adisbladis/adios)
│   └── korora/            Type system
└── patches/               Source patches
snix-redox/                snix source (Rust, cross-compiled for Redox)
```

## Development

```bash
nix develop            # Full dev environment
nix develop .#minimal  # Quick iteration
nix develop .#native   # Everything including legacy tools
```

## Credits

- **[Redox OS](https://www.redox-os.org/)** — the operating system
- **[adios](https://github.com/adisbladis/adios)** by
  [@adisbladis](https://github.com/adisbladis) — module system and Korora
  type system, vendored in `nix/vendor/`
- **[snix](https://snix.dev/)** — snix-eval bytecode VM (vendored, patched for Redox)
- **[Nix](https://nixos.org/)** — the build system making this reproducible

## License

Redox OS components are licensed under their respective upstream licenses (MIT).
