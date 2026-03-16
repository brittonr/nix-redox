## Why

`snix system rebuild` has two paths: local (evaluates a simplified config attrset, resolves package names from a JSON index) and bridge (sends config to the host, host does real Nix evaluation and builds). The bridge path produces correct results — real derivations, real closures, proper package resolution. The local path fakes package resolution with a flat JSON index, which we just had to fix three bugs in and still produces surprising behavior (specifying `packages = ["ripgrep"]` wipes every non-boot-essential package).

The bridge path is the right mechanism for package changes but requires the user to explicitly pass `--bridge`. A user who runs `snix system rebuild` after editing their packages list gets the broken local path by default. The bridge should be the default when available, and the local path should be scoped to config-only changes where it works correctly.

## What Changes

- `snix system rebuild` auto-detects whether to use the bridge path based on: (1) whether `/scheme/shared` is mounted, and (2) whether the config changes include package modifications.
- If packages changed and the bridge is available: use bridge automatically, no `--bridge` flag needed.
- If packages changed and no bridge: error with a clear message explaining that package changes require the bridge (run the VM with `--shared`).
- If only config changed (hostname, timezone, DNS, etc.): use the local path regardless of bridge availability — it handles these correctly.
- `--bridge` flag remains as an explicit override to force bridge for any change.
- `--local` flag added to force the local path (even for package changes, for testing).
- The local rebuild path's package resolution via `packages.json` is kept but demoted — it only activates with `--local` or when the config has no package changes but the system already has packages with store paths in the manifest.
- Documentation in the generated `configuration.nix` and README updated to describe the rebuild workflow.

## Capabilities

### New Capabilities
- `rebuild-auto-routing`: Automatic detection of whether to use bridge or local rebuild path based on available infrastructure and type of configuration change.

### Modified Capabilities
- `guest-rebuild`: The local rebuild path is restricted to config-only changes by default. Package changes route to bridge or error.

## Impact

- **snix-redox/src/main.rs** — dispatch logic for `SystemCommand::Rebuild` changes to call auto-routing instead of checking `bridge` flag directly.
- **snix-redox/src/rebuild.rs** — new `auto_rebuild()` entry point that inspects the parsed config and available infrastructure to choose the path. `rebuild()` (local) may reject package changes unless `--local` is passed.
- **snix-redox/src/bridge.rs** — no protocol changes, but called from the new auto-routing logic.
- **nix/redox-system/modules/build/generated-files.nix** — update the default `configuration.nix` comments to explain the rebuild workflow.
- **README.md** — update rebuild section.
- **nix/redox-system/profiles/rebuild-generations-test.nix** — update Phase 8 (package addition) to use `--bridge` or `--local` explicitly.
