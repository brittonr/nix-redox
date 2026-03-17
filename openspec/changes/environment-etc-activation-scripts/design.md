## Context

The module system generates config files in `generated-files.nix` via a hardcoded `allGeneratedFiles` attrset. Adding a new file (e.g., `/etc/motd`) requires editing internal build code. Activation (`activate.rs`) has placeholder comments for pre/post hooks but no mechanism for user-defined scripts.

NixOS provides `environment.etc` for arbitrary file injection and `system.activationScripts` for running commands during activation. Both are heavily used by modules and end-user configs. Without these primitives, every new config file or setup step requires changing the build internals.

The adios module system already supports typed options and profile overrides. The build module already merges `allGeneratedFiles` into the root tree and `activate.rs` already runs a structured activation sequence. Both features slot cleanly into existing infrastructure.

## Goals / Non-Goals

**Goals:**
- Profiles and user configs can declare arbitrary `/etc/` files without touching `generated-files.nix`
- Profiles and user configs can declare activation scripts that run during `snix system switch`
- Activation scripts run in dependency order with named deps
- Both features work with the existing generation/rollback system — no special handling needed
- Existing hardcoded generated files keep working unchanged (merged alongside `environment.etc`)

**Non-Goals:**
- Service management (restart, dependency graphs) — that's a separate tier 2 change
- Imperative activation (running services, restarting daemons) — Redox init doesn't support runtime service control yet
- Sandboxing activation scripts — they run as root, same as the rest of init
- `environment.etc` for binary files from derivations (source-from-derivation) — text and mode only for now

## Decisions

### 1. `environment.etc` lives in the existing `/environment` module

Add an `etc` option (attrset of `{ text, mode }` structs) directly to `environment.nix`. This parallels NixOS's `environment.etc` and keeps related config together. The build module merges these entries into `allGeneratedFiles` after the hardcoded files, so user entries can override defaults.

Alternative considered: separate `/etc` module. Rejected because it splits a single concern across two modules and the `/environment` module already handles system packages, shell aliases, and variables — config files fit naturally.

### 2. Activation scripts get a new `/activation` adios module

Create `nix/redox-system/modules/activation.nix` with a `scripts` option (attrset of `{ text, deps }` structs). This parallels NixOS's `system.activationScripts`.

Alternative considered: add to `/services`. Rejected because services are boot-time init scripts (numbered, rendered to init.d), while activation scripts run during live `snix system switch`. Different lifecycle, different module.

### 3. Scripts stored in rootTree at `/etc/redox-system/activation.d/`

Activation script contents are written to the root tree as executable files. The manifest tracks them in a new `activationScripts` field (list of `{ name, deps }`). During `snix system switch`, `activate.rs` reads the manifest, topologically sorts by deps, and executes each script from disk.

Alternative considered: embed script text in manifest JSON. Rejected because scripts can be multi-line and large — disk files are cleaner and can be inspected/debugged independently.

### 4. Topological sort with cycle detection in activate.rs

Deps are a list of script names that must run before this script. `activate.rs` performs a topological sort and errors on cycles. This matches NixOS's `system.activationScripts.*.deps` semantics.

Alternative considered: numeric ordering (like init scripts). Rejected because named deps are more robust — inserting a new script doesn't require renumbering, and the dependency intent is explicit.

### 5. `environment.etc` entries can use `source` (derivation path) as alternative to `text`

Support both `text = "content"` and `source = someDrv` for file content. `text` is inline string content, `source` is a path to copy. This matches how `generated-files.nix` already handles the shadow file (`source = shadowFile`). Mode defaults to `"0644"`.

### 6. User `etc` entries override built-in ones

When an `environment.etc` key conflicts with a hardcoded generated file (e.g., user sets `etc."etc/hostname"`), the user's entry wins. This is accomplished by merging user entries after hardcoded ones with `//`. Matches NixOS behavior where user `environment.etc` can override module-generated files.

## Risks / Trade-offs

- [Script execution failures] → Activation scripts that fail (non-zero exit) are logged as warnings but don't abort the switch. Matches NixOS behavior — activation is best-effort.
- [Dep cycle in activation scripts] → `activate.rs` detects cycles at switch time and refuses to run, printing the cycle. Build-time assertion would be better but requires Nix-side topo sort — deferred.
- [Large etc entries bloating manifest] → Manifest only stores file hashes and activation script metadata (name + deps), not content. Content stays in rootTree files.
- [Activation scripts can't read stdin] → They run non-interactively during switch. Scripts that need user input won't work. Documented in option description.
