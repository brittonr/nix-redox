# My Redox OS System

A custom Redox OS configuration built with Nix.

## Usage

```bash
# Boot headless with interactive serial console (QEMU — default)
nix run

# Boot graphical desktop with Orbital (QEMU + GTK)
nix run .#graphical

# Fast headless boot (Cloud Hypervisor, no interactive serial)
nix run .#cloud-hypervisor

# Build just the disk image
nix build
```

QEMU is the default because its serial console supports interactive I/O.
For graphical mode, set `/graphics.enable = true` in `configuration.nix`
and use `nix run .#graphical`.

## Configuration

Edit `configuration.nix` to customize your system. The file is a Nix function
that returns module option values — same idea as NixOS's `configuration.nix`.

After editing, `nix run` rebuilds and boots the new image.

## What you can configure

| Module | Examples |
|---|---|
| `/environment` | `systemPackages`, `shellAliases`, `variables`, `etc` (file injection) |
| `/networking` | `enable`, `mode` (auto/dhcp/static), `dns`, `remoteShellEnable` |
| `/graphics` | `enable`, `resolution`, `virtualTerminal`, `loginCommand` |
| `/users` | User accounts with uid, gid, home, shell, password, `createHome` |
| `/services` | `ssh.enable`, `httpd.enable`, `getty`, custom daemons |
| `/activation` | Scripts that run on system switch (with dependency ordering) |
| `/security` | `requirePasswords`, `protectKernelSchemes`, `namespaceAccess` |
| `/time` | `hostname`, `timezone`, `ntpEnable`, `ntpServers` |
| `/hardware` | `audioEnable`, `storageDrivers`, `networkDrivers`, `extraPciDrivers` |
| `/boot` | `diskSizeMB`, `espSizeMB`, `espLabel`, `initfsSizeMB`, `kernelSyscallDebug` |
| `/power` | `acpiEnable`, `powerAction`, `idleAction`, `idleTimeoutMinutes` |
| `/logging` | `level`, `kernelLogLevel`, `logToFile`, `maxLogSizeMB` |
| `/programs` | `editor`, `ion.prompt`, `helix.{enable, theme}`, `cargo.buildJobs` |
| `/virtualisation` | `memorySize`, `cpus`, `qemuMachineType`, `tapInterface`, `sharedFsDir` |
| `/system` | `name`, `version`, `target` |
| `/snix` | `stored.enable`, `profiled.enable`, `sandbox` |
| `/filesystem` | `extraDirectories`, `devSymlinks`, `extraPaths` |

## Available packages

All packages from the [redox](https://github.com/brittonr/redox) flake are
available via the `pkgs` argument. Common ones:

`ion` `uutils` `extrautils` `helix` `sodium` `smith` `snix` `redox-bash`
`ripgrep` `fd` `bat` `hexyl` `zoxide` `dust` `lsd` `bottom` `tokei`
`shellharden` `redox-curl` `redox-git` `gnu-make` `redox-diffutils`
`redox-sed` `redox-patch` `strace-redox` `userutils` `netutils`
`orbital` `orbterm` `orbutils` `orbdata`
