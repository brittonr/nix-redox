## Context

Service declarations are centralized in `init-scripts.nix` (~320 lines of per-module conditional blocks). Each block reads `cfg.*` fields from `config.nix` which extracts values from module inputs. The rendering engine (topo sort, auto-numbering, init script generation) is solid and doesn't need changes.

The adios module system passes options through `inputs` — the build module sees each module's computed options but not their `impl` results. Modules currently use pass-through impls (`impl = { options }: options`).

adios supports `defaultFunc` on options: a function receiving `{ options, inputs }` from the module's own args fixpoint. This lets an option's default value depend on other options or cross-module inputs. `/boot` already uses this pattern (`defaultFunc = { inputs }: inputs.pkgs.pkgs.kernel or { }`).

## Goals / Non-Goals

**Goals:**
- Each domain module declares its own services as a computed option
- `/build` collects services from all module inputs instead of hardcoding per-module blocks
- Shared `serviceType` definition used by all modules for type safety
- No changes to the rendering engine (topo sort, auto-numbering, init script generation)
- All existing tests pass without modification

**Non-Goals:**
- Changing adios framework internals
- Changing the service rendering or topo sort algorithm
- Changing how profiles declare services (the `/services.services` attrset remains)
- Adding new services or changing service behavior
- Modifying initfs scripts (only rootfs services are affected)

## Decisions

### 1. Service type lives in a shared lib file

Extract `serviceType` from `services.nix` to `nix/redox-system/lib/service-type.nix`. The file takes `{ t }` (korora types) and returns the struct type. Each module imports it:

```nix
adios:
let
  t = adios.types;
  serviceType = import ../lib/service-type.nix { inherit t; };
in
```

**Why not `t.attrs`**: Loses type checking at module boundaries. A typo in a field name would propagate silently to rendering.

**Why not adios custom types**: adios has a types mechanism per-module but no cross-module type sharing. A plain import is simpler and idiomatic Nix.

### 2. Modules use `defaultFunc` on a `services` option

Each module adds:

```nix
options = {
  # ... existing options ...
  services = {
    type = t.attrsOf serviceType;
    defaultFunc = { options, ... }:
      if options.enable then { smolnetd = { ... }; } else { };
  };
};
```

The `defaultFunc` computes service entries based on the module's own options. Profiles can override individual services by setting e.g. `/networking.services.smolnetd.priority = 15`.

**Why `defaultFunc` over `impl`**: `impl` results aren't wired to inputs in adios. `defaultFunc` is the existing mechanism for computed values that depend on other options. It keeps services as part of the options attrset, which `/build` already reads through `inputs`.

### 3. `/services` gets `/pkgs` input for userutilsInstalled

The `/services` module needs to know if userutils is in the package set to:
- Resolve `getty.enable = "auto"` → true/false
- Enable/disable sudod

Adding `/pkgs` as an input lets the `services` option's `defaultFunc` check package availability. This is the same pattern `/boot` uses.

### 4. `/graphics` gets `/hardware` and `/pkgs` inputs

Graphics services need:
- `hardware.audioEnable` → whether to include audiod
- `pkgs.orbutils` → login command fallback (orblogin vs login)

### 5. `/services` owns core + typed + cross-cutting services

The `/services` module's `services` option `defaultFunc` generates:
- **Core**: ipcd, ptyd (always on, explicit priority 10/11)
- **Typed**: ssh, httpd, getty, exampled (from typed service options)
- **Cross-cutting**: sudod (depends on userutilsInstalled)

Profile-declared services (`/services.services`) override these via normal attrset merge.

### 6. init-scripts.nix collects from inputs

Replace the ~280 lines of per-module service blocks with:

```nix
moduleServices =
  inputs.services.services
  // inputs.networking.services
  // inputs.graphics.services
  // inputs.snix.services
  // inputs.iroh.services;
```

Right-side wins on key collision (profile overrides module defaults). The rest of the file (topo sort, rendering, raw initScripts) stays unchanged.

### 7. config.nix drops service-related fields

Fields like `networkingServices`, `graphicsServices`, `sshEnabled`, `gettyEnabled`, `userutilsInstalled` move out of config.nix. The `userutilsInstalled` check moves into `/services`'s `defaultFunc`. Service-specific `cfg.*` fields used only by init-scripts.nix's service blocks are eliminated.

Fields used by other parts of the build (e.g., `cfg.graphicsEnabled` for initfs, `cfg.networkingEnabled` for generated-files) remain.

## Risks / Trade-offs

**[Risk] defaultFunc circular dependency** → Service options must not reference themselves. Each module's `services.defaultFunc` reads `options.enable`, `options.mode`, etc. — never `options.services`. Nix laziness handles the fixpoint.

**[Risk] Module input ordering affects merge precedence** → The `//` merge in init-scripts.nix means later inputs override earlier ones. Document the merge order. Profile-declared services (from `inputs.services.services`) already take precedence since they're user-specified.

**[Risk] cfg.* field removal breaks other consumers** → Audit every `cfg.*` reference before removing. Some fields (like `userutilsInstalled`) are used by generated-files.nix for /etc file generation, not just services. Those must move to the module that uses them or stay in config.nix.

**[Trade-off] Modules gain complexity** → Each service-declaring module grows ~20-40 lines for the `services` option. init-scripts.nix shrinks by ~280 lines. Net reduction in total code, and the remaining code is co-located with its domain.
