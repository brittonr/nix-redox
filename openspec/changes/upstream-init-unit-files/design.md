## Context

The upstream init binary now uses a `UnitStore` that loads `.service` and `.target` TOML files from `config_dirs` (set by `SwitchRoot`). The boot sequence is:

1. `main()` calls `SwitchRoot { prefix: "/scheme/initfs", etcdir: "/scheme/initfs/etc", target: Some("90_initfs.target") }.apply()`
2. `apply()` sets `config_dirs = [prefix/lib/init.d, etcdir/init.d]`, then loads `00_runtime.target` and `90_initfs.target` via `load_units()` which recursively resolves `requires_weak` dependencies
3. Units are processed in dependency order — `default_dependencies = true` (default) means "wait for `00_runtime.target`"
4. After `90_initfs.target` completes, init calls `SwitchRoot { prefix: "/usr", etcdir: "/etc", target: None }` which loads ALL unit files from the rootfs init.d dirs
5. `logd` is started explicitly (hardcoded) between the two `SwitchRoot` calls, with `switch_stdio("/scheme/log")`

Our module system currently generates shell scripts with `export`/`scheme`/`notify`/`run.d` commands. The rendering must change to produce TOML unit files, but the declaration API (structured service options with type, command, args, environment, after, wantedBy) maps cleanly to the new format.

## Goals / Non-Goals

**Goals:**
- Generate `.service` and `.target` TOML files that the upstream init binary can parse
- Map our existing service declaration fields to the TOML unit file schema
- Produce the required `00_runtime.target` and `90_initfs.target` entry points
- Keep the NixOS-style module declaration API unchanged — modules still declare services with `type`, `command`, `args`, `environment`, `after`, `wantedBy`
- Handle both initfs (early boot) and rootfs (post-mount) service directories
- Remove hardcoded shell commands (`export PATH`, `run.d`, `switchroot`) from init script text

**Non-Goals:**
- Implementing the full systemd unit model (wants, conflicts, etc.) — we only need `requires_weak`
- Changing service startup behavior (notify, scheme, oneshot) — these map 1:1
- Adding new service types beyond what already exists
- Template/instance units (`ramfs@.service` pattern) — generate concrete units for each instance instead

## Decisions

### Unit file format follows upstream TOML schema exactly

The init binary uses `serde::Deserialize` with `#[serde(deny_unknown_fields)]`. Any extra fields cause a parse error. The format is:

```toml
# .service files
[unit]
description = "..."
default_dependencies = false  # optional, defaults to true
requires_weak = ["dep1.service", "dep2.target"]

[service]
cmd = "binary"
args = ["arg1", "arg2"]
type = "notify"              # or "oneshot", "oneshot_async", { scheme = "name" }
envs = { KEY = "value" }     # static env vars (replaces our `export KEY VALUE`)
inherit_envs = ["VAR"]       # inherit from parent process env

# .target files
[unit]
description = "..."
requires_weak = ["svc1.service", "svc2.service"]
```

### Dependency model: `requires_weak` replaces numeric ordering

Old model: services get numeric prefixes (15-79) via topological sort. Services at lower numbers run first.

New model: each unit declares `requires_weak = [...]`. The init binary resolves dependencies at load time, processing units only when all their deps have been processed. Numeric prefixes in filenames are kept for directory listing order but are not semantically meaningful.

Our topological sort in `init-scripts.nix` still runs to compute the auto-numbering, but now also emits `requires_weak` referencing the actual dependency unit filenames.

### Service type mapping

| Our type | TOML `type` field |
|----------|-------------------|
| `scheme` | `{ scheme = "name" }` (inline table) |
| `daemon` / `notify` | `"notify"` |
| `oneshot` | `"oneshot"` |
| `nowait` | `"oneshot_async"` |

### Initfs scripts become a mix of `.service`, `.target`, and legacy scripts

The initfs `etc/init.d/` directory needs:
- `00_runtime.target` — groups null/zero/rand/rtcd
- Individual `.service` files for each initfs daemon
- `90_initfs.target` — the entry point that transitively requires rootfs mount
- Our custom scripts (generation select, boot banner) can use legacy format — the init binary's `UnitKind::LegacyScript` path still works for extensionless files

### Rootfs services go to `usr/lib/init.d/` as `.service` files

After `90_initfs.target`, init does `SwitchRoot { prefix: "/usr", etcdir: "/etc" }` and loads units from `/usr/lib/init.d/` and `/etc/init.d/`. Our rootfs services (smolnetd, orbital, getty, etc.) get written as `.service` files to `usr/lib/init.d/`.

### logd is hardcoded in init — remove from our service declarations

The new init starts `logd` explicitly between the two `SwitchRoot` calls. We should NOT declare logd as a service — it's handled by init directly. Remove it from our generated services.

### `switchroot`/`run.d`/`export PATH` eliminated from init script text

The `90_exit_initfs` script used `run.d`, `export PATH`, `export LD_LIBRARY_PATH`. These are now handled by init's `SwitchRoot` struct. The initfs target just needs to declare its deps; the switchroot happens automatically after `90_initfs.target`.

Post-switchroot env vars (TERM, HOME, USER, CARGO_HOME, etc.) that we currently set in `90_exit_initfs` need a new home — either a rootfs legacy script or env vars in the `SwitchRoot` config (if we patch init).

## Risks / Trade-offs

- **Legacy script fallback**: The init binary still supports extensionless legacy scripts via `UnitKind::LegacyScript`. We can use this for custom scripts that don't fit the service/target model (boot banner, generation select). Risk: upstream may remove this path.
- **logd ordering**: The hardcoded logd between switchroots means our logging service declaration is dead code. If upstream changes this, we'd need to adapt.
- **env var setup**: Post-switchroot environment variables (TERM, XDG_CONFIG_HOME, HOME, LD_LIBRARY_PATH for self-hosting) don't have a clean place in the new model. A legacy rootfs script is the pragmatic choice.
- **`deny_unknown_fields`**: The init binary rejects unknown TOML keys. Our generated files must exactly match the schema — no extra metadata fields.
