# Examples

Example Redox OS configurations. Each directory is a standalone Nix flake
you can `cd` into and `nix run`.

| Example | What it is |
|---|---|
| [minimal](minimal/) | Bare shell + coreutils, no graphics, no network. 512 MB disk. |
| [my-redox-system](my-redox-system/) | Kitchen-sink starter config with all modules demonstrated. |
| [graphical-desktop](graphical-desktop/) | Orbital desktop with terminal, file manager, Helix. |
| [dev-workstation](dev-workstation/) | Headless with ripgrep, fd, bat, snix, make, strace. 1.5 GB disk. |

## Quick start

```bash
cd examples/minimal
nix run
```

Each example has its own `README.md` with usage details.

## Creating your own

Copy any example directory, edit `configuration.nix`, and `nix run`.
The `my-redox-system` example has comments explaining every module.
