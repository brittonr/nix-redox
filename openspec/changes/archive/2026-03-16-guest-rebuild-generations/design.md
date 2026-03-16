## Context

`snix system rebuild` (rebuild.rs), `snix system switch` (system.rs), `snix system rollback` (system.rs), and `snix system generations` (system.rs) are implemented but have only been tested in two ways:

1. **Host-side unit tests** (504 tests) cover snix internals but not these system management paths, which depend on a live Redox filesystem.
2. **Bridge-rebuild-test** exercises the `--bridge` flag path where the host does the actual Nix evaluation and build. The guest just sends a JSON config blob over virtio-fs and installs the result.

The local rebuild path — where the guest evaluates `configuration.nix` itself, resolves package names against its on-disk binary cache, merges into the running manifest, and activates — has zero test coverage. Same for generations: `switch()` creates generation dirs, `rollback()` restores them, `generations()` lists them, but no test has ever run these against RedoxFS.

The test infrastructure is well established. Functional-test (152 tests), self-hosting-test (66 tests), scheme-native-test (22 tests), and bridge-test (45 tests) all use the same pattern: Ion shell test script emitting `FUNC_TEST:name:PASS/FAIL` lines, parsed by the host test harness from serial output. A new test profile slots in directly.

Key constraints from AGENTS.md:
- Ion shell: `let var = "value"`, `end` not `fi`, `$()` crashes on empty output
- `grep` has no alternation — use separate calls
- No `sleep`, `tail`, `sed`, `awk`, `find`
- `std::fs::canonicalize()` returns `file:/path` — strip prefix
- Scheme daemon interactions: profiled and stored may be running during tests
- FUNC_TEST protocol: emit PASS/FAIL directly, don't rely on `$?` between commands

## Goals / Non-Goals

**Goals:**
- Test the local `snix system rebuild` path end-to-end inside a running VM (no bridge)
- Test generation lifecycle: creation on switch, listing, rollback to previous state
- Fix bugs discovered by the tests (path handling, permission issues, missing files)
- Add the test as `nix run .#rebuild-generations-test` in the flake

**Non-Goals:**
- Changing the rebuild/switch/rollback API or adding new features to them
- Testing the bridge rebuild path (already covered by bridge-rebuild-test)
- Testing `snix system upgrade` via channels (requires network, separate concern)
- Rewriting the activation system
- Multi-user profile management (only system profile tested here)

## Decisions

### 1. Single test profile covering both rebuild and generations

Both capabilities share the same setup (booted system with a manifest and binary cache). The test runs sequentially: first verify the current system state, then rebuild with a config change, then check generations, then rollback. One profile, one boot, one test run.

*Alternative: Separate profiles.* Rejected — the boot overhead is 30-60s per VM and the tests are naturally sequential (rollback depends on having a prior generation from a rebuild).

### 2. Test against the on-disk binary cache, not network

The development and self-hosting profiles already embed a binary cache at `/nix/cache/` with all system packages. The test profile extends development to include a populated packages.json index. This avoids network dependencies and tests the same code path users would hit offline.

*Alternative: HTTP cache via QEMU SLiRP.* Rejected — network-install-test already covers that path. This test focuses on local-only operation.

### 3. Use a minimal configuration.nix change (hostname)

The test modifies `hostname` in configuration.nix — a change that doesn't require installing new packages or restarting services, just config file updates. This isolates the rebuild→activate pipeline from package resolution complexity.

A second test adds a package name to `packages = [...]` to verify package resolution against the cache index works.

*Alternative: Test with large package changes.* Rejected for the first pass — package resolution failures should be debugged separately from the rebuild pipeline.

### 4. Verify generations via filesystem inspection, not just snix output

Ion shell's `$()` crashes on empty output and `$?` is unreliable between commands. Rather than parsing `snix system generations` output in Ion, the test directly checks for generation directories in `/etc/redox-system/generations/` and compares manifest.json files using `grep`.

### 5. Test profile extends development (not self-hosting)

Self-hosting includes the full Rust toolchain (400MB+), which is unnecessary for testing rebuild/generations. The development profile has all the packages needed plus snix.

*Alternative: Extend minimal.* Rejected — minimal lacks too many tools (no grep, no bash) making test assertions painful.

## Risks / Trade-offs

- **[Eval may fail on Redox]** `snix system rebuild` calls the snix evaluator to parse `configuration.nix`. The evaluator works for `snix build --expr` and `snix eval --expr`, but `evaluate_config()` in rebuild.rs uses a specific eval path that may hit edge cases. → Mitigation: the test starts with `snix system show-config` (read-only) before attempting rebuild.
- **[File permission issues on RedoxFS]** Generation dirs need mkdir + write. RedoxFS handles permissions differently from Linux. → Mitigation: tests check for specific error messages and the code already uses `fs::create_dir_all`.
- **[canonicalize prefix]** `std::fs::canonicalize()` returns `file:/path` on Redox. If rebuild.rs or system.rs uses canonicalize internally, paths break. → Mitigation: grep the source for canonicalize calls and fix any found.
- **[Cache index missing]** The default `packages.json` at `/nix/cache/packages.json` may not exist on test images. → Mitigation: the build module already generates the binary cache; verify it includes the index or add it.
