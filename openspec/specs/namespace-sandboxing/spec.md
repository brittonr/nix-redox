### Requirement: Restricted namespace for builders

When `local_build.rs` executes a derivation builder, it SHALL create a restricted scheme namespace for the child process. The namespace SHALL contain `memory`, `pipe`, `rand`, `null`, and `zero` schemes. The namespace SHALL NOT contain `file` directly — instead, a proxy scheme daemon SHALL be registered as `file` in the child namespace, providing filtered filesystem access. FOD builds SHALL additionally get `net`.

| Mode | file: scheme | Filesystem access | Status |
|------|-------------|-------------------|--------|
| Full (proxy) | proxy daemon | allow-list only | **Default** |
| Fallback (scheme-only) | real redoxfs | everything | Fallback on proxy failure |
| Unsandboxed | real redoxfs | everything | `--no-sandbox` / config |

#### Scenario: Normal derivation build
- **WHEN** snix builds a derivation that is NOT a fixed-output derivation
- **THEN** the child namespace SHALL contain `memory`, `pipe`, `rand`, `null`, `zero`
- **AND** a proxy SHALL be registered as `file` in the child namespace
- **AND** the proxy SHALL enforce the derivation's allow-list
- **AND** the child SHALL NOT have access to `net:`, `display:`, `disk:`, or other schemes

#### Scenario: Fixed-output derivation build
- **WHEN** snix builds a fixed-output derivation (has `outputHash` attribute)
- **THEN** the child namespace SHALL contain `memory`, `pipe`, `rand`, `null`, `zero`, `net`
- **AND** a proxy SHALL be registered as `file` in the child namespace
- **AND** the proxy SHALL enforce the derivation's allow-list

#### Scenario: Builder attempts unauthorized scheme access
- **WHEN** a builder tries to open a path in a scheme not in its namespace (e.g., `display:`)
- **THEN** the kernel SHALL return `ENOENT` (scheme not found in process namespace)

### Requirement: Namespace setup via Redox syscalls

Namespace restriction SHALL use Redox's `mkns` to create a child namespace, `register_scheme_to_ns` to register the proxy as `file` in that namespace, and `setns` in the child's `pre_exec` to switch to the restricted namespace.

#### Scenario: Namespace created with mkns
- **WHEN** snix prepares to build a derivation
- **THEN** snix SHALL call `mkns([memory, pipe, rand, null, zero])` to create a child namespace fd
- **AND** the `file` scheme SHALL NOT be in the `mkns` scheme list

#### Scenario: Proxy registered via register_scheme_to_ns
- **WHEN** the child namespace fd is created
- **THEN** snix SHALL call `register_scheme_to_ns(child_ns_fd, "file", cap_fd)` to register the proxy

#### Scenario: Child switches namespace in pre_exec
- **WHEN** snix forks a child process for the builder
- **THEN** the child SHALL call `setns(child_ns_fd)` in `pre_exec` BEFORE calling `exec()` on the builder

#### Scenario: Parent process unaffected
- **WHEN** the child process switches to the restricted namespace
- **THEN** the parent snix process SHALL retain its full namespace

### Requirement: Graceful fallback without namespace support

If the Redox kernel does not support namespace restriction or proxy registration fails, the builder SHALL execute with scheme-only sandboxing (real `file:` in the namespace). If scheme-only sandboxing also fails, the builder SHALL execute without sandboxing. Warnings SHALL be emitted to stderr at each fallback step.

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

#### Scenario: mkns returns ENOSYS
- **WHEN** `mkns()` returns `ENOSYS`
- **THEN** snix SHALL log "warning: namespace sandboxing unavailable, running builder unsandboxed"
- **AND** SHALL execute the builder with full scheme access (including real `file:`)

#### Scenario: Namespace restriction disabled by flag
- **WHEN** snix is run with `--no-sandbox` flag or `SNIX_NO_SANDBOX=1` or `sandbox=disabled` in `/etc/snix/config`
- **THEN** snix SHALL skip namespace setup and proxy creation entirely

### Requirement: Output directory isolation

The builder SHALL have `file:` scheme access restricted to its output directory (`$out`), the temp build directory (`$TMPDIR`), and resolved input store paths. The proxy SHALL create parent directories automatically when the builder opens a file with `O_CREAT` under a writable path. The builder SHALL NOT be able to read or write arbitrary filesystem paths.

#### Scenario: Builder creates nested output directory
- **WHEN** the builder calls `open("$out/lib/rustlib/target/lib/libcore.rlib", O_CREAT|O_WRONLY)`
- **AND** `$out/lib/rustlib/target/lib/` does not exist
- **THEN** the proxy SHALL create all intermediate directories
- **AND** create the file

#### Scenario: Builder writes to $out
- **WHEN** the builder creates files under its `$out` directory
- **THEN** the write SHALL succeed (proxy allows read-write to `$out`)

#### Scenario: Builder writes to $TMPDIR
- **WHEN** the builder creates temporary files in `$TMPDIR`
- **THEN** the write SHALL succeed (proxy allows read-write to `$TMPDIR`)

#### Scenario: Builder reads /etc/passwd
- **WHEN** the builder attempts to read `/etc/passwd`
- **THEN** the proxy SHALL return `EACCES` (not on allow-list)

#### Scenario: Builder writes to /nix/store directly
- **WHEN** the builder attempts to create files in `/nix/store/` outside its `$out`
- **THEN** the proxy SHALL return `EACCES`

### Requirement: Input store path visibility

The builder's filesystem access via the proxy SHALL include the store paths declared as inputs in the derivation. The builder SHALL NOT be able to read arbitrary store paths through the proxied `file:` scheme.

#### Scenario: Builder reads declared input
- **WHEN** the derivation declares `inputDrvs: { /nix/store/abc.drv: ["out"] }` where the `out` output is `/nix/store/def-dep`
- **AND** the builder opens `/nix/store/def-dep/lib/libfoo.so`
- **THEN** the proxy SHALL forward the open to the real filesystem and return success

#### Scenario: Builder reads undeclared store path
- **WHEN** the builder opens `/nix/store/xyz-other-pkg/bin/foo`
- **AND** `xyz-other-pkg` is NOT in the derivation's inputs
- **THEN** the proxy SHALL return `EACCES`

#### Scenario: Builder reads its own output
- **WHEN** the builder writes to its `$out` directory and then reads it back
- **THEN** the proxy SHALL allow both the write and the subsequent read

### Requirement: Self-hosting builds run sandboxed by default

The self-hosting test profile SHALL NOT override `sandbox = false`. All builds in the self-hosting test suite SHALL execute with the per-path proxy enabled.

#### Scenario: self-hosting-test.nix sandbox config removed
- **WHEN** the self-hosting test profile is loaded
- **THEN** the `/snix` module SHALL NOT set `sandbox = false`
- **AND** snix SHALL use the default sandbox mode (proxy enabled)

#### Scenario: All 62 self-hosting tests pass with sandbox
- **WHEN** the self-hosting test suite runs with the proxy enabled
- **THEN** all 62 tests SHALL pass
- **AND** no test SHALL require `--no-sandbox` to succeed
