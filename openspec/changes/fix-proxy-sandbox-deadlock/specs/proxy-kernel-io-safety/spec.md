## MODIFIED Requirements

### Requirement: Proxy-owned scheme threads can forward real filesystem I/O without hanging

When the snix build proxy owns a child-namespace `file:` scheme socket and services builder requests, the proxy SHALL keep real redoxfs and `/dev/*` syscalls off the scheme event-loop thread so allow-listed opens, reads, writes, and directory scans complete without hanging the proxy.

#### Scenario: Proxy opens declared input through worker-backed forward
- **WHEN** the proxy thread receives an allow-listed open for `/nix/store/<hash>-dep/lib/libfoo.so`
- **THEN** the proxy forwards the real redoxfs open through its dedicated I/O worker
- **AND** the builder receives a usable proxied handle without the proxy hanging

#### Scenario: Proxy writes builder output through worker-backed forward
- **WHEN** the builder opens or writes an allow-listed path under `$out`
- **THEN** the proxy forwards the create/write through its dedicated I/O worker
- **AND** the write completes without hanging the proxy event loop

### Requirement: Safe forwarding does not widen unrelated filesystem access

The worker-thread fix and proxy integration SHALL keep filesystem access scoped to the proxy allow-list. Unauthorized paths SHALL remain blocked.

#### Scenario: Proxy denies unrelated unauthorized path
- **WHEN** the builder requests a path that is not on the proxy allow-list
- **THEN** the proxy returns `EACCES`
- **AND** using the worker path does not grant general filesystem access

### Requirement: snix uses per-path proxy sandbox by default

`snix build` SHALL prefer the per-path proxy sandbox by default. If proxy setup fails, snix SHALL emit a warning and fall back to the scheme-only sandbox instead of silently pretending proxy mode is active.

#### Scenario: Proxy setup succeeds
- **WHEN** snix starts a sandboxed local build and `setup_proxy_namespace()` succeeds
- **THEN** snix registers the proxy `file:` scheme in the child namespace
- **AND** the builder runs with the per-path allow-list enforced

#### Scenario: Proxy setup fails
- **WHEN** `setup_proxy_namespace()` returns an error
- **THEN** snix logs a warning that proxy mode is unavailable
- **AND** snix falls back to the scheme-only sandbox

### Requirement: Deadlock regression is covered by focused and workload validation

The repo SHALL keep a fast regression that exercises repeated worker-backed proxy forwarding and a larger sandbox validation that proves the restored proxy survives real cargo build workloads.

#### Scenario: Focused reproducer passes
- **WHEN** `proxy_namespace_test` runs its repeated worker-cycle regression
- **THEN** it completes its write/read cycles and reports PASS

#### Scenario: Sandbox suite passes with proxy mode
- **WHEN** the sandbox validation suite runs
- **THEN** the suite completes with proxy mode enabled
- **AND** at least one real build workload proves cargo subprocesses can build through the proxy without hanging
