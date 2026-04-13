## ADDED Requirements

### Requirement: Proxy-owned scheme processes can forward real filesystem opens without deadlock

When a snix build proxy owns a scheme socket in the child namespace and forwards an allow-listed path through a pre-opened real filesystem root fd, the kernel SHALL allow the forwarded `openat` path to complete instead of deadlocking the process.

#### Scenario: Proxy opens declared input through pre-opened root fd
- **WHEN** the proxy process owns the child namespace `file:` scheme socket
- **AND** the proxy issues `SYS_OPENAT(root_fd, "nix/store/<hash>-dep/lib/libfoo.so", ...)` through a pre-opened real root fd
- **THEN** the kernel returns a usable fd for the real file
- **AND** the proxy can read bytes and return them to the builder

#### Scenario: Proxy writes builder output through pre-opened root fd
- **WHEN** the proxy process owns the child namespace `file:` scheme socket
- **AND** the builder opens an allow-listed path under `$out`
- **THEN** the proxy can create or open the output path through the pre-opened real root fd
- **AND** the write completes without hanging the process

### Requirement: Safe forwarding does not widen unrelated filesystem access

The kernel fix and snix proxy integration SHALL keep the allowed forwarding path tied to the proxy's pre-opened real filesystem descriptors and the proxy allow-list. Unrelated unauthorized paths SHALL remain blocked.

#### Scenario: Proxy denies unrelated unauthorized path
- **WHEN** the builder requests a path that is not on the proxy allow-list
- **AND** the proxy process owns the child namespace `file:` scheme socket
- **THEN** the proxy returns `EACCES`
- **AND** the kernel does not turn the safe forwarding path into general access to unrelated filesystem paths

#### Scenario: Safe forwarding remains scoped to proxy descriptors
- **WHEN** a process owns a scheme socket but does not use the proxy's pre-opened real filesystem descriptors for an allow-listed forward
- **THEN** the kernel does not treat that process as generally exempt from scheme-socket-owner filesystem restrictions
- **AND** only the proxy's intended forwarding path is allowed to proceed

### Requirement: snix uses per-path proxy sandbox by default when safe forwarding is available

`snix build` SHALL prefer the per-path proxy sandbox on kernels that satisfy the safe forwarding requirement. If the capability is unavailable, snix SHALL emit a warning and fall back to the scheme-only sandbox instead of silently pretending proxy mode is active.

#### Scenario: Safe forwarding available
- **WHEN** snix starts a sandboxed local build on a kernel that supports safe proxy forwarding
- **THEN** snix registers the proxy `file:` scheme in the child namespace
- **AND** the builder runs with the per-path allow-list enforced

#### Scenario: Safe forwarding unavailable
- **WHEN** snix starts a sandboxed local build on a kernel that does not support safe proxy forwarding
- **THEN** snix logs a warning that proxy mode is unavailable
- **AND** snix falls back to the scheme-only sandbox

### Requirement: Deadlock regression is covered by focused and workload validation

The repo SHALL keep a fast regression that exercises the former scheme-socket-owner deadlock path and a larger sandbox validation that proves the restored proxy survives real cargo build workloads.

#### Scenario: Focused reproducer passes
- **WHEN** the proxy deadlock reproducer runs on a fixed kernel
- **THEN** it completes its open/read/write round-trip and reports PASS

#### Scenario: Sandbox suite passes with proxy mode
- **WHEN** the sandbox validation suite runs on a fixed kernel
- **THEN** the suite completes with proxy mode enabled
- **AND** at least one real build workload proves cargo subprocesses can build through the proxy without deadlocking
