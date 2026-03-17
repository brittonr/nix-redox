# Dev Workstation

Headless system loaded with developer tools: Helix, ripgrep, fd, bat,
snix package manager, diffutils, sed, patch, make, and strace.

Networking and remote shell are enabled. Login as `dev` / `redox`.

```bash
nix run         # Cloud Hypervisor with serial console
nix run .#qemu  # QEMU with serial console
nix build       # produces the disk image
```

The 1.5 GB disk and 4 GB RAM give room for `snix build` on-device.
