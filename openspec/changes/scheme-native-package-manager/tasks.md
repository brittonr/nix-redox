## 1. Store Scheme Daemon (`stored`)

- [x] 1.1 Create `snix-redox/src/stored/mod.rs` with the scheme daemon skeleton: register `store` scheme via `open("/scheme/store", O_CREAT)`, enter the `Packet` read loop, dispatch by syscall number (`SYS_OPEN`, `SYS_READ`, `SYS_WRITE`, `SYS_CLOSE`, `SYS_FSTAT`, `SYS_FPATH`). Use `virtio-fsd` as the reference implementation for the scheme protocol.
- [x] 1.2 Implement handle table in `stored`: `BTreeMap<usize, HandleEntry>` where `HandleEntry` tracks the underlying `fs::File` or directory iterator, the resolved filesystem path, and the open mode. Allocate handles on open, release on close.
- [x] 1.3 Implement path resolution: parse scheme-relative paths (`abc...-ripgrep/bin/rg`) → validate store path hash format (32 nixbase32 chars) → check PathInfoDb → resolve to `/nix/store/{hash}-{name}/{subpath}`.
- [x] 1.4 Implement `SYS_READ` handler: read from the underlying `fs::File` at the requested offset and length. Handle partial reads and EOF.
- [x] 1.5 Implement `SYS_FSTAT` handler: stat the resolved filesystem path, return `Stat` struct with size, mode, timestamps.
- [x] 1.6 Implement directory listing (`SYS_READ` on directory handles): iterate `/nix/store/{hash}-{name}/` entries for store path directories. For the root (`store:`), list all registered store path names from PathInfoDb.
- [x] 1.7 Implement lazy extraction trigger: when `SYS_OPEN` resolves a store path that exists in PathInfoDb but is NOT extracted to `/nix/store/`, locate the NAR in the local cache, decompress, verify hash, extract to `/nix/store/`, then complete the open. Use a `Mutex<HashSet<String>>` to track in-progress extractions and block concurrent openers on the same store path.
- [x] 1.8 Implement PathInfoDb reload on cache miss: when a store path is not found in the in-memory index, re-scan PathInfoDb for the hash before returning `ENOENT`. This handles paths registered by `snix install` while `stored` is running.
- [x] 1.9 Add `stored` binary entry point: new `[[bin]]` in `Cargo.toml` (or separate crate) with `fn main()` that initializes logging, opens PathInfoDb, registers the scheme, and enters the request loop.
- [x] 1.10 Write unit tests for path resolution, handle table allocation/deallocation, and directory listing logic. These tests run on Linux using mock filesystems (no scheme registration needed).

## 2. Profile Scheme Daemon (`profiled`)

- [x] 2.1 Create `snix-redox/src/profiled/mod.rs` with the scheme daemon skeleton: register `profile` scheme, enter `Packet` read loop. Handle `SYS_OPEN`, `SYS_READ`, `SYS_CLOSE`, `SYS_FSTAT`, `SYS_WRITE` (for control interface).
- [x] 2.2 Implement profile mapping table: `BTreeMap<String, ProfileMapping>` where `ProfileMapping` contains `Vec<ProfileEntry>` with `(name: String, store_path: String, installed_at: u64)`. Load from `/nix/var/snix/profiles/{name}/mapping.json` on startup.
- [x] 2.3 Implement union path resolution: for `profile:default/bin/rg`, iterate the `default` profile's entries in reverse installation order, check if `{store_path}/bin/rg` exists on the filesystem, return the first match. Cache resolution results with a TTL or invalidate on mapping mutation.
- [x] 2.4 Implement union directory listing: for `profile:default/bin/`, collect all `bin/` entries across all packages in the profile, dedup by filename (last-installed-wins for conflicts), return the merged directory listing.
- [x] 2.5 Implement the `.control` write interface: parse JSON commands from writes to `profile:{name}/.control`. Support `{"action": "add", "name": "...", "storePath": "..."}` and `{"action": "remove", "name": "..."}`. Validate inputs, update mapping, persist atomically.
- [x] 2.6 Implement atomic mapping persistence: write to `mapping.json.tmp`, then `rename()` to `mapping.json`. This ensures no partial states from crashes.
- [x] 2.7 Implement multi-profile support: the first path component selects the profile (`default`, `dev`, `system`). Listing `profile:` returns all profile names. Each profile has independent state.
- [x] 2.8 Add `profiled` binary entry point: new `[[bin]]` in `Cargo.toml` with `fn main()` that initializes, loads mappings, registers scheme, enters request loop.
- [x] 2.9 Write unit tests for mapping table operations (add, remove, lookup, persist, load), union resolution, conflict handling, and directory listing merge. Tests run on Linux using temp directories.

## 3. Namespace Sandboxing for Builds

- [x] 3.1 Research Redox's current namespace API: examine `redox_syscall` crate for `setns()`, `SYS_SETNS`, or namespace table manipulation. Check the Redox kernel source for the current implementation status. Document findings in a code comment.
- [x] 3.2 Create `snix-redox/src/sandbox.rs` with `setup_build_namespace()` function: takes the derivation's input store paths and output path, configures the child process namespace to allow `file:` (restricted paths) and `store:` (restricted to input hashes). Feature-gated behind `#[cfg(target_os = "redox")]`.
- [x] 3.3 Implement FOD detection: check if the derivation has `outputHash`/`outputHashAlgo`/`outputHashMode` attributes. If yes, additionally allow `net:` scheme access in the namespace.
- [x] 3.4 Implement input path allowlist: build a `HashSet<String>` of allowed store path hashes from the derivation's `input_derivations` (resolved output paths) and `input_sources`. Pass this to the namespace setup to restrict `store:` visibility.
- [x] 3.5 Integrate into `local_build.rs`: modify `build_derivation()` to call `setup_build_namespace()` in the pre-exec hook (between `fork()` and `exec()`). On `ENOSYS`/`EPERM`, log warning and continue unsandboxed.
- [x] 3.6 Add `--no-sandbox` CLI flag to `snix build` that skips namespace setup entirely.
- [x] 3.7 Add `sandbox` feature to `Cargo.toml` with `#[cfg(target_os = "redox")]` default enablement. Ensure Linux builds exclude all `redox_syscall` namespace code.
- [x] 3.8 Write unit tests for input path allowlist construction and FOD detection logic. These run on Linux (no actual namespace calls). Add integration test docs for VM-based sandbox verification.

## 4. snix CLI Integration

- [x] 4.1 Modify `install.rs`: after fetching and extracting a package, check if `profiled` is running by attempting `open("profile:default/.control")`. If available, write the add command instead of creating symlinks. Fall back to symlinks if unavailable.
- [x] 4.2 Modify `install.rs` `remove()`: check if `profiled` is running, write remove command to `.control` if available. Fall back to symlink removal.
- [x] 4.3 Add `snix stored` subcommand to `main.rs` that runs the `stored` daemon (for manual startup/debugging).
- [x] 4.4 Add `snix profiled` subcommand to `main.rs` that runs the `profiled` daemon.
- [x] 4.5 Add `snix install --lazy` flag that registers the package in PathInfoDb and profile mapping WITHOUT extracting the NAR. This is the natural mode when `stored` is running (extraction happens on first access). When `stored` is not running, `--lazy` is a no-op (extraction is required for filesystem access).
- [x] 4.6 Update `snix profile list` to read from `profiled` when available (open and parse `profile:default/.control` with a list command), falling back to the manifest file.

## 5. Module System Integration

- [x] 5.1 Create `nix/redox-system/modules/snix.nix` adios module: options for `stored.enable` (bool, default false), `profiled.enable`, and `sandbox`. When enabled, generates init.d scripts for stored/profiled startup. Combined into a single `/snix` module path (cleaner than separate modules).
- [x] 5.2 Wire stored/profiled into build module: generates `12_stored` and `13_profiled` init.d scripts when enabled. stored starts before profiled (profiled can resolve via store paths). Both use `nowait` for background daemon startup.
- [x] 5.3 Sandbox option at `/snix.sandbox` (bool, default true). Generates `/etc/snix/config` with sandbox=enabled/disabled. CLI `--no-sandbox` flag also controls this per-invocation.
- [x] 5.4 Created `scheme-native` profile preset that extends development with all three capabilities enabled. Minimal profile unaffected (defaults are all disabled).
- [x] 5.5 stored/profiled ship as `snix stored` / `snix profiled` subcommands in the snix-redox binary. No separate package definitions needed — they're already part of the snix package that's included in systemPackages.

## 6. Testing

- [x] 6.1 Write unit tests for `stored` core logic: path resolution, handle table, lazy extraction trigger, concurrent access blocking. Run on Linux with mock PathInfoDb and temp directories. (30 tests — done in prior commit)
- [x] 6.2 Write unit tests for `profiled` core logic: mapping CRUD, union resolution, directory listing merge, conflict handling, atomic persistence. Run on Linux with temp directories. (20 tests — done in prior commit)
- [x] 6.3 Write unit tests for `sandbox.rs`: input allowlist construction, FOD detection, fallback behavior. Run on Linux. (7 tests — done in prior commit + 3 new integration tests for sandbox wiring in local_build.rs)
- [x] 6.4 Integration tests for new code: 5 tests for profiled/stored detection (always false on Linux = correct fallback), 3 sandbox wiring tests (config construction, FOD network, no_sandbox flag). VM-level scheme tests deferred to when daemons are exercised on real Redox hardware.
- [x] 6.5 All existing tests pass: 439 host unit tests (was 431), all Nix module system eval checks pass (eval-profile-default, eval-profile-minimal, eval-profile-functional-test, artifact-rootTree-has-passwd). Zero regressions.
- [x] 6.6 Bridge/functional test compatibility verified: no changes to bridge or functional test code. profiled/stored fallback to false on non-Redox, so all existing test paths are unchanged.

## 7. Documentation

- [x] 7.1 Update `CLAUDE.md` with the new architecture: scheme daemons, namespace sandboxing, fallback behavior, new CLI flags and subcommands. Module tree updated to 16 modules, key options include `/snix`, new "Redox Scheme Daemons" section added.
- [x] 7.2 Inline documentation already thorough in `stored/mod.rs` and `profiled/mod.rs` from prior commit — architecture diagrams, path layouts, scheme protocol, handle lifecycle, fallback behavior all documented in module-level doc comments.
- [x] 7.3 Napkin updated with scheme daemon integration lessons: module system wiring, init script numbering, Nix syntax pitfalls, profiled detection, lazy install fallback, SandboxConfig ownership for pre_exec, build_derivation split pattern.
