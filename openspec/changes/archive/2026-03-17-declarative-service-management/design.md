## Context

Redox's init system runs numbered scripts from `/etc/init.d/` (initfs phase) and `/usr/lib/init.d/` + `/etc/init.d/` (rootfs phase, via `run.d`). Scripts execute in sorted order. Services start with `notify` (block until ready), `nowait` (fire-and-forget), or `scheme <name> <cmd>` (scheme daemon).

Today, `init-scripts.nix` has ~250 lines of `lib.optionalAttrs` conditionals that emit raw init script text. The `services.services` structured type exists in `services.nix` but no profile uses it. Each module (networking, graphics, snix) has no way to declare its own services — everything is centralized in the build module.

NixOS solves this with `systemd.services.<name>` options declared per module. We can't use systemd, but we can follow the same pattern: each module declares its services, and the build module renders them to numbered init scripts.

## Goals / Non-Goals

**Goals:**
- Each module declares its own services through `services.services` structured entries
- Explicit dependency ordering replaces implicit numeric prefix assignment
- The build module auto-numbers scripts from the dependency DAG
- Service environment variables are part of the declaration, not raw script text
- Manifest tracks full service metadata for richer activation diffs
- All existing profiles produce identical boot behavior after migration

**Non-Goals:**
- Runtime service supervision (restart on crash, health checks) — Redox init has no supervision loop
- Service lifecycle management during `snix system switch` (start/stop/restart) — services require reboot
- Cgroups, resource limits, or sandboxing per service
- Socket activation or on-demand service startup
- Replacing the init daemon itself

## Decisions

### 1. Service declarations live in each module, not centralized

Each module (networking.nix, graphics.nix, snix.nix) sets `"/services".services.<name>` in its impl output. The build module merges all declarations.

**Why not keep centralized**: The current approach couples service knowledge to the build module. Adding a new daemon means editing init-scripts.nix, not the module that owns the feature. Per-module declarations follow the NixOS pattern and keep related config together.

**Alternative**: A separate `services/` module directory with one file per service. Rejected — too much ceremony for a system with ~15 services. The module that owns the feature should own the service declaration.

### 2. Dependency ordering via `after` field, auto-numbered output

Services declare `after = [ "ptyd" "ipcd" ];` — names of other services that must start first. The build module topologically sorts the service DAG and assigns numeric prefixes (00, 01, 02, ...) to produce the init script filenames.

**Why not keep manual numbering**: Manual numbering is fragile (gaps, collisions) and requires knowing the global ordering when adding a service. Topo sort + auto-numbering is what NixOS does internally with systemd unit ordering.

**Tie-breaking**: Services at the same depth get alphabetical ordering (deterministic, reproducible builds).

### 3. Two phases: `initfs` and `rootfs`

Services declare `wantedBy = "initfs"` or `wantedBy = "rootfs"` (default). Initfs services go in `etc/init.d/`, rootfs services go in `usr/lib/init.d/`. Dependencies cannot cross phase boundaries (initfs services cannot depend on rootfs services).

The existing `wantedBy` field in `serviceType` already handles this. No change needed.

### 4. `environment` attrset on serviceType

```nix
environment = { VT = "3"; XDG_CONFIG_HOME = "/etc"; };
```

Rendered as `export KEY VALUE` lines before the service command in the init script. This replaces the pattern of embedding `export` in raw script text.

### 5. Manifest stores service objects, not just script names

Current manifest:
```json
"services": { "initScripts": ["00_base", "10_net"], "startupScript": "/startup.sh" }
```

New manifest:
```json
"services": {
  "declared": {
    "smolnetd": { "type": "daemon", "command": "/bin/smolnetd", "wantedBy": "rootfs" },
    "getty": { "type": "nowait", "command": "getty /scheme/debug/no-preserve -J", "wantedBy": "rootfs" }
  },
  "initScripts": ["00_runtime", "10_smolnetd", ...],
  "startupScript": "/startup.sh"
}
```

The activation plan can then show "service smolnetd added (daemon)" rather than "script 10_net added".

### 6. Migration: raw initScripts remain as escape hatch

The `initScripts` option stays for cases that don't fit the service model (multi-command setup blocks like `00_runtime` and `90_exit_initfs`). These are numbered explicitly and always sort before/after auto-numbered services.

Reserved ranges:
- `00-09`: Raw initfs setup scripts (runtime, logging)
- `10-79`: Auto-numbered from service declarations
- `80-89`: Raw boot-time hooks (generation activation)
- `90-99`: Raw exit/transition scripts

## Risks / Trade-offs

- **Risk**: Init script ordering changes could break boot → Mitigation: Build check compares generated init scripts against a known-good snapshot for each test profile. Any ordering change in existing profiles fails the check.
- **Risk**: Module merging order affects service declarations → Mitigation: Services are keyed by name (attrset merge with `//`), so declaration order doesn't matter. Duplicate names from different modules are a build error (checked in build assertions).
- **Trade-off**: Auto-numbering makes init script filenames less human-readable (10_smolnetd vs 42_smolnetd) → Accepted, since the dependency graph is the source of truth, not the numbers.
- **Trade-off**: Manifest format change is not backwards-compatible → Manifests already use `manifestVersion` field. Bump to v3, v2 reader falls back gracefully.
