## Why

Service declarations for networking, graphics, snix, and iroh are hardcoded in the build module's `init-scripts.nix`. Adding or modifying a service means editing a central 645-line file that knows about every module, instead of the module that owns the domain. This couples service lifecycle to the build pipeline and makes the module system less composable.

## What Changes

- Extract shared `serviceType` to `nix/redox-system/lib/service-type.nix` so modules can declare typed services
- Add `services` option (via `defaultFunc`) to `/networking`, `/graphics`, `/snix`, `/iroh` modules — each computes its own service entries based on its options
- Add `/pkgs` input to `/services` module so it can resolve `userutilsInstalled` for getty "auto" mode and sudod
- Add `/hardware` and `/pkgs` inputs to `/graphics` module for audiod and orbutils login command
- `/services` module becomes the "service registry" — owns core services (ipcd, ptyd), typed service modules (ssh, httpd, getty, exampled, sudod), and profile-declared services
- Simplify `init-scripts.nix` to collect `.services` from all module inputs, merge, topo sort, and render — no more per-module conditional blocks
- Remove corresponding `cfg.*` service fields from `config.nix`

## Capabilities

### New Capabilities
- `module-owned-services`: Modules declare their own services via computed options, collected and rendered by the build module

### Modified Capabilities
- `declarative-services`: Service declarations move from build-module hardcoding to module-owned computed options while preserving topo sort, auto-numbering, and rendering

## Impact

- `nix/redox-system/modules/networking.nix` — adds `services` option with `defaultFunc`, adds `inputs` if needed
- `nix/redox-system/modules/graphics.nix` — adds `services` option with `defaultFunc`, adds `/hardware` and `/pkgs` inputs
- `nix/redox-system/modules/snix.nix` — adds `services` option with `defaultFunc`
- `nix/redox-system/modules/iroh.nix` — adds `services` option with `defaultFunc`
- `nix/redox-system/modules/services.nix` — adds `/pkgs` input, moves core + typed service generation into `impl` output
- `nix/redox-system/modules/build/init-scripts.nix` — replaces ~280 lines of per-module service blocks with input collection
- `nix/redox-system/modules/build/config.nix` — removes service-related `cfg.*` fields
- `nix/redox-system/lib/service-type.nix` — new shared type definition
- All existing eval/artifact/VM tests must continue to pass unchanged
