## ADDED Requirements

### Requirement: Restricted namespace for builders

When `local_build.rs` executes a derivation builder, it SHALL create a restricted scheme namespace for the child process. The namespace SHALL only contain the schemes necessary for the build: `file:` (for the output directory and temp), `store:` (for reading declared inputs), and optionally `net:` (for fixed-output derivations).

#### Scenario: Normal derivation build
- **WHEN** snix builds a derivation that is NOT a fixed-output derivation
- **THEN** the builder process SHALL have access to `file:` and `store:` schemes only
- **AND** SHALL NOT have access to `net:`, `display:`, `disk:`, or other schemes

#### Scenario: Fixed-output derivation build
- **WHEN** snix builds a fixed-output derivation (has `outputHash` attribute)
- **THEN** the builder process SHALL have access to `file:`, `store:`, and `net:` schemes
- **AND** `net:` access is required because FODs fetch content by URL

#### Scenario: Builder attempts unauthorized scheme access
- **WHEN** a builder tries to open a path in a scheme not in its namespace (e.g., `display:`)
- **THEN** the kernel SHALL return `ENOENT` (scheme not found in process namespace)

### Requirement: Input store path visibility

The builder's `store:` scheme access SHALL be limited to the store paths declared as inputs in the derivation. The builder SHALL NOT be able to read arbitrary store paths, only those listed in `input_derivations` (resolved outputs) and `input_sources`.

#### Scenario: Builder reads declared input
- **WHEN** the derivation declares `inputDrvs: { /nix/store/abc.drv: ["out"] }` where the `out` output is `/nix/store/def-dep`
- **AND** the builder opens `store:def-dep/lib/libfoo.so`
- **THEN** the open SHALL succeed

#### Scenario: Builder reads undeclared store path
- **WHEN** the builder opens `store:xyz-other-pkg/bin/foo`
- **AND** `xyz-other-pkg` is NOT in the derivation's inputs
- **THEN** the open SHALL return `ENOENT` (path not visible in restricted namespace)

#### Scenario: Builder reads its own output
- **WHEN** the builder writes to its `$out` directory
- **THEN** the builder SHALL have write access to that specific store path via `file:` scheme

### Requirement: Output directory isolation

The builder SHALL have `file:` scheme access restricted to its output directory (`$out`), the temp build directory (`$TMPDIR`), and essential system paths (`/dev/null`, `/dev/urandom`). The builder SHALL NOT be able to read or write arbitrary filesystem paths.

#### Scenario: Builder writes to $out
- **WHEN** the builder creates files under its `$out` directory
- **THEN** the write SHALL succeed

#### Scenario: Builder writes to $TMPDIR
- **WHEN** the builder creates temporary files in `$TMPDIR`
- **THEN** the write SHALL succeed

#### Scenario: Builder reads /etc/passwd
- **WHEN** the builder attempts to read `/etc/passwd`
- **THEN** the read SHALL fail (not in the allowed file paths)

#### Scenario: Builder writes to /nix/store directly
- **WHEN** the builder attempts to create files in `/nix/store/` outside its `$out`
- **THEN** the write SHALL fail

### Requirement: Namespace setup via Redox syscalls

Namespace restriction SHALL use Redox's native `SYS_SETNS` or equivalent namespace manipulation syscalls from the `redox_syscall` crate. The implementation SHALL set up the namespace BEFORE calling `exec()` on the builder binary, in the forked child process.

#### Scenario: Namespace set before exec
- **WHEN** snix forks a child process for the builder
- **THEN** the child SHALL call `setns()` to restrict its scheme visibility BEFORE calling `exec()` on the builder

#### Scenario: Parent process unaffected
- **WHEN** the child process restricts its namespace
- **THEN** the parent snix process SHALL retain its full namespace (namespace restriction is per-process)

### Requirement: Graceful fallback without namespace support

If the Redox kernel does not support namespace restriction (syscall returns `ENOSYS` or `EPERM`), the builder SHALL execute without sandboxing, exactly as it does today. A warning SHALL be emitted to stderr.

#### Scenario: Namespace syscall unavailable
- **WHEN** `setns()` returns `ENOSYS`
- **THEN** snix SHALL log "warning: namespace sandboxing unavailable, running builder unsandboxed"
- **AND** SHALL execute the builder with full scheme access (current behavior)

#### Scenario: Namespace syscall permission denied
- **WHEN** `setns()` returns `EPERM`
- **THEN** snix SHALL log the warning and fall back to unsandboxed execution

#### Scenario: Namespace restriction disabled by flag
- **WHEN** snix is run with `--no-sandbox` flag
- **THEN** snix SHALL skip namespace setup entirely

### Requirement: Cargo feature gate

Namespace sandboxing SHALL be behind a `sandbox` cargo feature in `snix-redox/Cargo.toml`. When the feature is disabled (default on non-Redox targets), all namespace code SHALL be compiled out. When enabled (default on Redox target), the namespace setup SHALL be included.

#### Scenario: Build for Linux (tests)
- **WHEN** snix is compiled for `x86_64-unknown-linux-gnu` (for testing)
- **THEN** the `sandbox` feature SHALL be disabled and all namespace code excluded

#### Scenario: Build for Redox
- **WHEN** snix is compiled for `x86_64-unknown-redox`
- **THEN** the `sandbox` feature SHALL be enabled by default

## MODIFIED Requirements

### Requirement: Builder execution in local_build.rs (modified)

The `build_derivation()` function SHALL be modified to set up namespace restrictions before executing the builder. The modification SHALL preserve the existing unsandboxed behavior as a fallback.

#### Scenario: Sandboxed build (happy path)
- **GIVEN** namespace support is available and the `sandbox` feature is enabled
- **WHEN** `build_derivation()` executes a builder
- **THEN** it SHALL fork, call `setup_build_namespace()` in the child, then exec the builder

#### Scenario: Unsandboxed fallback
- **GIVEN** namespace support is unavailable or the `sandbox` feature is disabled
- **WHEN** `build_derivation()` executes a builder
- **THEN** it SHALL execute the builder via `Command::new()` as it does today (inherited stdio, env_clear)
