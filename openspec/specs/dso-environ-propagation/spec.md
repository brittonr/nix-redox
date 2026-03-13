## ADDED Requirements

### Requirement: ld.so injects environ into loaded DSOs
The dynamic linker (`ld_so`) SHALL write the process's `environ` pointer into a `__relibc_init_environ` static in each loaded DSO during `run_init()`, before calling `.init_array` functions. This mirrors the existing injection pattern for `__relibc_init_ns_fd`, `__relibc_init_proc_fd`, and `__relibc_init_cwd_ptr`.

#### Scenario: DSO reads parent environ
- **WHEN** a dynamically-linked program is executed with `FOO=bar` in its environment
- **THEN** code running inside a loaded .so file can read `FOO` via `std::env::var("FOO")` or `getenv("FOO")`

#### Scenario: Command::env propagates through exec
- **WHEN** a Rust program runs `Command::new("child").env("MY_VAR", "value").exec()`
- **THEN** the child process (even if dynamically linked) sees `MY_VAR=value` in its environment

#### Scenario: Proc-macro crate reads CARGO_PKG env vars
- **WHEN** cargo compiles a proc-macro crate that uses `env!("CARGO_PKG_NAME")`
- **THEN** the proc-macro expansion succeeds without `--env-set` workaround

### Requirement: Version script exports environ init symbol
relibc's version script SHALL export `__relibc_init_environ` in the global section, alongside the existing `__relibc_init_ns_fd`, `__relibc_init_proc_fd`, `__relibc_init_cwd_ptr`, and `__relibc_init_cwd_len` symbols.

#### Scenario: Symbol visible in .so
- **WHEN** `llvm-nm` is run on a built relibc .so
- **THEN** `__relibc_init_environ` appears as a defined data symbol

### Requirement: --env-set workaround removable
After the DSO environ fix lands, the `--env-set` cargo patch (patch-cargo-env-set.py) SHALL be removable without breaking proc-macro compilation. The removal MUST be validated by the self-hosting test passing without `--env-set`.

#### Scenario: Self-hosting test passes without --env-set
- **WHEN** the self-hosting-test profile runs cargo builds without --env-set
- **THEN** all proc-macro crates (thiserror-impl, serde_derive) compile successfully

#### Scenario: Fallback available during transition
- **WHEN** the DSO environ fix is deployed but not yet fully validated
- **THEN** the --env-set workaround can be re-enabled by restoring patch-cargo-env-set.py

### Requirement: Patch delivered as Python scripts
The fix SHALL be implemented as two patch scripts: `patch-relibc-environ-dso.py` (adds the `__relibc_init_environ` static to relibc) and an update to `patch-relibc-run-init.py` (extends `run_init()` to inject environ). Both SHALL be idempotent.

#### Scenario: Patches apply cleanly
- **WHEN** both patch scripts run against the relibc source tree
- **THEN** they modify the relevant files and exit 0

#### Scenario: Patches are idempotent
- **WHEN** both patch scripts run twice on the same source tree
- **THEN** the second run detects existing changes and skips
