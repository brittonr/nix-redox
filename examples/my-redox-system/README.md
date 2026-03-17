# My Redox OS System

A custom Redox OS configuration built with Nix.

## Usage

```bash
# Boot the graphical desktop
nix run

# Boot headless with serial console
nix run .#headless

# Build just the disk image
nix build
```

## Configuration

Edit `configuration.nix` to customize your system. The file is a Nix function
that returns module option values — same idea as NixOS's `configuration.nix`.

After editing, `nix run` rebuilds and boots the new image.

## What you can configure

| Module | Examples |
|---|---|
| `/environment` | `systemPackages`, `shellAliases`, `variables`, `etc` (file injection) |
| `/networking` | `enable`, `mode` (auto/dhcp/static), `dns`, `remoteShellEnable` |
| `/graphics` | `enable`, `resolution` |
| `/users` | User accounts with uid, gid, home, shell, password |
| `/services` | `ssh.enable`, `httpd.enable`, `getty`, custom daemons |
| `/activation` | Scripts that run on system switch (with dependency ordering) |
| `/security` | `requirePasswords`, `protectKernelSchemes` |
| `/time` | `hostname`, `timezone` |
| `/hardware` | `audioEnable`, `storageDrivers`, `networkDrivers` |
| `/boot` | `diskSizeMB`, `initfsSizeMB` |
| `/power` | `acpiEnabled`, `powerAction` |

## Available packages

All packages from the [redox](https://github.com/brittonr/redox) flake are
available via the `pkgs` argument. Common ones:

`ion` `uutils` `extrautils` `helix` `sodium` `smith` `snix` `redox-bash`
`ripgrep` `fd` `bat` `hexyl` `zoxide` `dust` `lsd` `bottom` `tokei`
`shellharden` `redox-curl` `redox-git` `gnu-make` `redox-diffutils`
`redox-sed` `redox-patch` `strace-redox` `userutils` `netutils`
`orbital` `orbterm` `orbutils` `orbdata`
