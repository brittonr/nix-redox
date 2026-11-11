# NixOS integration

The flake exports NixOS modules for using Redox tooling from a NixOS host:

```nix
{
  inputs.redox.url = "github:brittonr/nix-redox";

  outputs = { self, nixpkgs, redox, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        redox.nixosModules.default
        {
          programs.redox.enable = true;
          services.redox-vm = {
            enable = true;
            profile = "graphical";
            memory = 4096;
            vmm = "qemu";
          };
        }
      ];
    };
  };
}
```

`programs.redox` installs the host tools (`fstools`, `redox-rebuild`).
`services.redox-vm` adds a systemd service that boots the selected profile.

## Options

| Option | Default | Purpose |
|---|---|---|
| `programs.redox.enable` | `false` | Install Redox host tools |
| `programs.redox.binaryCacheUrl` | `""` | Optional substituter for Redox packages |
| `programs.redox.binaryCachePublicKey` | `""` | Public key for the substituter |
| `services.redox-vm.enable` | `false` | Enable the VM service |
| `services.redox-vm.profile` | `default` | `default`, `minimal`, `graphical`, or `cloud` |
| `services.redox-vm.vmm` | `cloud-hypervisor` | `cloud-hypervisor` or `qemu` |
| `services.redox-vm.memory` | `2048` | VM memory in MiB |
| `services.redox-vm.cpus` | `4` | Virtual CPUs |
| `services.redox-vm.stateDir` | `/var/lib/redox-vm` | VM state directory |
| `services.redox-vm.networking.*` | disabled | TAP networking settings |

The module does not inject a private cache or public key. Set
`binaryCacheUrl`/`binaryCachePublicKey` explicitly, or configure
`nix.settings` yourself. The eval tier includes a NixOS module evaluation
check that asserts these defaults and the opt-in cache behavior.
