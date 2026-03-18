# Dev Workstation

Headless system loaded with developer tools: Helix, ripgrep, fd, bat,
snix package manager, diffutils, sed, patch, make, and strace.

Networking and remote shell are enabled. Login as `dev` / `redox`.

```bash
nix run                    # QEMU with interactive serial console
nix run .#cloud-hypervisor # fast headless (no interactive serial)
nix build                  # produces the disk image
```

The 1.5 GB disk and 4 GB RAM give room for `snix build` on-device.

## Syscall Debugging

`strace` is included. Trace any program from the Redox shell:

```sh
strace /bin/ls
strace cargo build 2> /tmp/trace.log
```

For kernel-level tracing (early boot, daemons), add to `configuration.nix`:

```nix
"/boot".kernelSyscallDebug = true;
```

See `docs/syscall-debugging.md` in the main repo for details.
