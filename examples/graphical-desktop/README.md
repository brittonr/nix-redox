# Graphical Redox OS Desktop

Orbital desktop with terminal emulator, file manager, and Helix editor.
Boots into a graphical login (user: `user`, password: `redox`).

```bash
nix run            # graphical desktop (QEMU + GTK window)
nix run .#headless # serial console only
nix build          # produces the disk image
```

Requires a display — runs QEMU with GTK, not Cloud Hypervisor.
