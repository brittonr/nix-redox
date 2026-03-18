## Why

The Redox OS book documents 45 crates as the official ecosystem. Our nix-redox build integrates 22 of them. Of the 23 missing, 7 are genuinely dead (ralloc replaced by dlmalloc, orbtk deprecated), but 8 are live infrastructure crates needed for bare metal support, debugging, package distribution, and driver development. We want bare metal parity, not just VM demos.

## What Changes

- Add **pkgutils** package: fix the ring crate git vendoring issue that blocks compilation, enabling the native Redox package manager (`pkg` command) alongside snix
- Add **gdb-protocol** library crate: GDB Remote Serial Protocol implementation, foundation for building GDB stubs for bare metal debugging
- Add **redox_intelflash** package: Intel SPI flash read/write tool for bare metal firmware management
- Add **redox-buffer-pool** library crate: zero-copy shared buffer management between drivers and clients, needed by future audio/graphics/USB drivers
- Add **redox-kprofiling** package: kernel profiling data converter, needed for performance tuning on real hardware
- Add **pkgar-repo** package: package repository server, completes the pkgar/pkgutils distribution stack
- Add **redoxer** package: canonical tool for running Redox programs from a Linux KVM host
- Add **slint_orbclient** library crate: Slint UI framework adapter for Orbital, enabling modern GUI applications

## Capabilities

### New Capabilities
- `pkgutils-package`: Fix ring crate vendoring and build pkgutils for Redox, providing the native `pkg` CLI
- `gdb-protocol-crate`: Cross-compile the gdb-protocol library for the Redox sysroot
- `intelflash-package`: Build redox_intelflash for bare metal Intel SPI flash operations
- `buffer-pool-crate`: Cross-compile redox-buffer-pool library for the Redox sysroot
- `kprofiling-package`: Build redox-kprofiling kernel profiling converter
- `pkgar-repo-package`: Build pkgar-repo package repository server
- `redoxer-package`: Build redoxer for host-side Redox program testing
- `slint-orbclient-crate`: Cross-compile slint_orbclient adapter for Orbital GUI apps

### Modified Capabilities

## Impact

- `flake.nix`: 8 new flake inputs (GitLab sources for each crate)
- `nix/flake-modules/packages.nix`: 8 new package definitions
- `nix/pkgs/userspace/`: 8 new .nix files (or fix existing pkgutils.nix)
- `nix/redox-system/profiles/development.nix`: pkgutils re-enabled, new tools added to system packages
- Disk image size: minimal increase — most are small Rust crates or lib-only
- Build time: each crate is independent, no cascading rebuilds
