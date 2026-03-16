## MODIFIED Requirements

### Requirement: Restricted namespace for builders

When `local_build.rs` executes a derivation builder, it SHALL create a restricted scheme namespace for the child process. The namespace SHALL contain `memory`, `pipe`, `rand`, `null`, and `zero` schemes. The namespace SHALL NOT contain `file` directly — instead, a proxy scheme daemon SHALL be registered as `file` in the child namespace, providing filtered filesystem access. FOD builds SHALL additionally get `net`.

> **Delta**: The proxy path is now production-ready and the default. Previously the proxy was experimental with automatic fallback to scheme-only sandbox (which included the real `file:` scheme). The sandbox mode table changes:
>
> | Mode | file: scheme | Filesystem access | Status |
> |------|-------------|-------------------|--------|
> | Full (proxy) | proxy daemon | allow-list only | **Default** |
> | Fallback (scheme-only) | real redoxfs | everything | Fallback on proxy failure |
> | Unsandboxed | real redoxfs | everything | `--no-sandbox` / config |

#### Scenario: Normal derivation build (MODIFIED)
- **WHEN** snix builds a derivation that is NOT a fixed-output derivation
- **THEN** the child namespace SHALL contain `memory`, `pipe`, `rand`, `null`, `zero`
- **AND** a proxy SHALL be registered as `file` in the child namespace
- **AND** the proxy SHALL enforce the derivation's allow-list
- **AND** the child SHALL NOT have access to `net:`, `display:`, `disk:`, or other schemes

> **Delta**: Added "the proxy SHALL enforce the derivation's allow-list". Previously this was aspirational; now the proxy is validated against the self-hosting suite.

#### Scenario: Fixed-output derivation build (MODIFIED)
- **WHEN** snix builds a fixed-output derivation (has `outputHash` attribute)
- **THEN** the child namespace SHALL contain `memory`, `pipe`, `rand`, `null`, `zero`, `net`
- **AND** a proxy SHALL be registered as `file` in the child namespace
- **AND** the proxy SHALL enforce the derivation's allow-list

> **Delta**: Added allow-list enforcement clause. FODs get `net` but their filesystem access is still restricted to declared inputs.

### Requirement: Graceful fallback without namespace support (MODIFIED)

If the Redox kernel does not support namespace restriction or proxy registration fails, the builder SHALL execute with scheme-only sandboxing (real `file:` in the namespace). If scheme-only sandboxing also fails, the builder SHALL execute without sandboxing. Warnings SHALL be emitted to stderr at each fallback step.

> **Delta**: Fallback now goes proxy → scheme-only → unsandboxed (three tiers). Previously, proxy failure went directly to unsandboxed because scheme-only was the primary path.

#### Scenario: Proxy setup fails, scheme-only succeeds
- **WHEN** `setup_proxy_namespace()` returns an error
- **AND** `setup_build_namespace()` succeeds
- **THEN** snix SHALL log "warning: per-path proxy failed ({error}), falling back to scheme-level sandbox"
- **AND** SHALL execute the builder with the real `file:` scheme in a restricted namespace

#### Scenario: Both proxy and scheme-only fail
- **WHEN** `setup_proxy_namespace()` returns an error
- **AND** `setup_build_namespace()` returns `Unavailable`
- **THEN** snix SHALL log both warnings
- **AND** SHALL execute the builder with full scheme access (unsandboxed)

#### Scenario: Namespace restriction disabled by flag (UNCHANGED)
- **WHEN** snix is run with `--no-sandbox` flag or `SNIX_NO_SANDBOX=1` or `sandbox=disabled` in `/etc/snix/config`
- **THEN** snix SHALL skip namespace setup and proxy creation entirely

### Requirement: Output directory isolation (MODIFIED)

The builder SHALL have `file:` scheme access restricted to its output directory (`$out`), the temp build directory (`$TMPDIR`), and resolved input store paths. The proxy SHALL create parent directories automatically when the builder opens a file with `O_CREAT` under a writable path.

> **Delta**: Added automatic parent directory creation. Cargo builds create deep output hierarchies (`$out/lib/rustlib/x86_64-unknown-redox/lib/`); the proxy must replicate the behavior of the real filesystem.

#### Scenario: Builder creates nested output directory (ADDED)
- **WHEN** the builder calls `open("$out/lib/rustlib/target/lib/libcore.rlib", O_CREAT|O_WRONLY)`
- **AND** `$out/lib/rustlib/target/lib/` does not exist
- **THEN** the proxy SHALL create all intermediate directories
- **AND** create the file

#### Scenario: Builder writes to $out (UNCHANGED)
- **WHEN** the builder creates files under its `$out` directory
- **THEN** the write SHALL succeed (proxy allows read-write to `$out`)

#### Scenario: Builder writes to $TMPDIR (UNCHANGED)
- **WHEN** the builder creates temporary files in `$TMPDIR`
- **THEN** the write SHALL succeed (proxy allows read-write to `$TMPDIR`)

#### Scenario: Builder reads /etc/passwd (UNCHANGED)
- **WHEN** the builder attempts to read `/etc/passwd`
- **THEN** the proxy SHALL return `EACCES` (not on allow-list)

#### Scenario: Builder writes to /nix/store directly (UNCHANGED)
- **WHEN** the builder attempts to create files in `/nix/store/` outside its `$out`
- **THEN** the proxy SHALL return `EACCES`

### Requirement: Self-hosting builds run sandboxed by default (ADDED)

The self-hosting test profile SHALL NOT override `sandbox = false`. All builds in the self-hosting test suite SHALL execute with the per-path proxy enabled.

#### Scenario: self-hosting-test.nix sandbox config removed
- **WHEN** the self-hosting test profile is loaded
- **THEN** the `/snix` module SHALL NOT set `sandbox = false`
- **AND** snix SHALL use the default sandbox mode (proxy enabled)

#### Scenario: All 62 self-hosting tests pass with sandbox
- **WHEN** the self-hosting test suite runs with the proxy enabled
- **THEN** all 62 tests SHALL pass
- **AND** no test SHALL require `--no-sandbox` to succeed
