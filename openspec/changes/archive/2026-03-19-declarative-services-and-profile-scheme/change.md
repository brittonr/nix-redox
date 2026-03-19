# Archive: Declarative Services & Profile Scheme

**Date:** 2026-03-19
**Specs:** declarative-services, profile-scheme
**Status:** Implemented — archiving as complete

## Declarative Services

Structured service declarations with dependency ordering, auto-numbering,
and manifest tracking. Replaces hand-numbered init scripts.

### Implementation

- **`nix/redox-system/modules/services.nix`** — Service type definitions
  (serviceType, initScriptType), typed service modules (ssh, httpd, getty,
  exampled), options schema with enable/command/type/args/wantedBy/after/
  environment/priority fields.

- **`nix/redox-system/modules/build/init-scripts.nix`** — Central service
  assembly. Module-derived services (core, networking, graphics, snix,
  console, ssh, httpd, sudo, exampled) merged with profile-declared
  services. Kahn's algorithm topo sort with cycle detection. Auto-numbering
  (15-79 range, core daemons pinned at 10-11). Rendering to numbered
  init.d scripts by type (daemon→notify, nowait→nowait, scheme→scheme,
  oneshot→bare). Raw initScripts coexistence. Service metadata export
  for manifest.

- **`nix/redox-system/modules/build/checks.nix`** — Build-time validation
  of service dependency graph (unknown refs, cycle detection via jq).

- **`nix/redox-system/modules/build/manifest.nix`** — Manifest v3 with
  `services.declared` object containing full service metadata.

- **`nix/redox-system/modules/build/config.nix`** — Config resolution for
  typed service modules (sshEnabled, gettyEnabled, etc).

- **`nix/redox-system/modules/build/generated-files.nix`** — Init script
  file generation from allInitScriptsWithServices, SSH/httpd config files.

### Spec Coverage

All 8 requirements covered:
1. Modules declare services through structured options — via build module
2. Services declare dependencies with after field — topo sort + cycle detection
3. Per-service environment variables — rendered as `export KEY VALUE`
4. Services rendered to numbered init scripts — auto-numbering 15-79
5. Raw initScripts coexist — explicit names, no auto-numbering
6. Service type determines command format — daemon/nowait/scheme/oneshot
7. Build check validates dependency graph — checks.nix jq validation
8. Manifest tracks full service declarations — manifest v3

### Tests

- **Eval tests** (`nix/tests/eval.nix`): service-ssh-enable,
  service-httpd-enable, service-getty-force, service-exampled-enable,
  service-all-together, service-sudod-with-userutils,
  service-sudod-without-userutils
- **Artifact tests** (`nix/tests/artifacts.nix`): rootTree-has-init-scripts,
  rootTree-has-graphical-init, rootTree-httpd-service,
  rootTree-sudod-init-script, services.ssh/httpd config tests

## Profile Scheme

Union package views via `profile:` Redox scheme daemon. No symlinks —
O(1) add, O(n) remove via in-memory mapping table.

### Implementation

- **`snix-redox/src/profiled/mod.rs`** (115 lines) — ProfiledConfig,
  ProfileDaemon entry point, module structure.

- **`snix-redox/src/profiled/scheme.rs`** (505 lines) — SchemeSync
  implementation. Path parsing (profile:name/subpath), open handler
  (file resolution, directory detection, .control interface), read/write
  handlers, getdents with union directory listings, stat handler.

- **`snix-redox/src/profiled/mapping.rs`** (800 lines) — ProfileStore
  with BTreeMap<String, ProfileMapping>. Load/persist mapping.json.
  list_union_from_manifests() for union directory views. Package
  manifest caching. add_package/remove_package mutations. Unit tests
  for union merging, empty profiles, last-writer-wins conflict resolution.

- **`snix-redox/src/profiled/handles.rs`** (365 lines) — HandleTable
  with typed handles (File, Dir, Control, SchemeRoot, ProfileRoot).
  FileIoWorker for background file reads. DirEntry buffering for
  getdents pagination.

- **`nix/redox-system/modules/snix.nix`** — profiled.enable,
  profiled.profilesDir, profiled.storeDir options.

- **`nix/redox-system/modules/build/init-scripts.nix`** — snixServices
  block generates profiled service entry when enabled.

### Spec Coverage

All 8 requirements covered:
1. Scheme daemon registration — scheme.rs SchemeSync impl, O_CREAT on /scheme/profile
2. Union directory view — list_union_from_manifests, last-writer-wins
3. Profile mapping table — BTreeMap in ProfileStore, mapping.json persistence
4. Instant package add/remove — mapping mutation only, no symlink creation
5. Profile directory traversal — parse_path, recursive subpath resolution
6. Multiple profile support — profile name as first path component
7. Control interface — .control write handler, JSON command processing
8. Graceful fallback — symlink-based profiles when daemon not running

### Test Coverage

- Unit tests in mapping.rs: list_union_merges_dirs, list_union_empty_profile
- Integration: profiled service generated in init-scripts.nix when snix.profiled.enable = true
