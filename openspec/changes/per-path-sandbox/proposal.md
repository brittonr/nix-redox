## Why

Nix build sandboxing requires per-path filesystem isolation: builders should only read their declared inputs from `/nix/store/`, write only to `$out` and `$TMPDIR`, and have no access to the host filesystem. On Linux, Nix achieves this with bind mounts and chroot. On Redox, the current sandbox uses scheme-level namespace filtering (`mkns`/`setns`), which is all-or-nothing for the `file:` scheme — a builder either gets full filesystem access or none. The proxy daemon infrastructure (`build_proxy` module, ~1300 lines) already exists in snix-redox but is disabled for complex builds because it hasn't been validated with deep process hierarchies (cargo→rustc→cc→lld) or high-crate-count workspaces.

## What Changes

- Validate the `BuildFsProxy` against the self-hosting test suite (62 tests including 193-crate snix build and 33-crate ripgrep build)
- Fix proxy handler issues revealed by real builds (file descriptor lifecycle, concurrent I/O, FUSE-like open flag translation, directory listing)
- Enable per-path sandbox by default for snix builds (remove `sandbox = false` override in self-hosting-test profile)
- Add proxy-specific test coverage: permission denied on undeclared paths, write-only to `$out`/`$TMPDIR`, read-only for store inputs
- Extend the `proxy_namespace_test` binary to validate full round-trip I/O through the proxy

## Capabilities

### New Capabilities

- `proxy-sandbox-validation`: End-to-end validation of per-path filesystem proxy under real cargo build workloads, covering the proxy event loop, allow-list enforcement, concurrent scheme request handling, and integration with snix's `local_build.rs` sandbox fallback logic

### Modified Capabilities

- `namespace-sandboxing`: Requirements change from scheme-level filtering (file: all-or-nothing) to per-path filtering (proxy intercepts file: and enforces allow-list). The sandbox mode table in the spec needs updating to reflect that the proxy path is production-ready, not experimental.

## Impact

- `snix-redox/src/build_proxy/handler.rs` — proxy event loop fixes for real-world I/O patterns
- `snix-redox/src/build_proxy/allow_list.rs` — possible allow-list expansion for edge cases (proc-macro output dirs, cargo metadata files)
- `snix-redox/src/build_proxy/lifecycle.rs` — proxy thread lifecycle hardening
- `snix-redox/src/local_build.rs` — sandbox setup path (remove fallback preference, proxy becomes default)
- `snix-redox/src/sandbox.rs` — updated sandbox mode documentation
- `snix-redox/tests/redox/proxy_namespace_test.rs` — extended with round-trip I/O tests
- `nix/redox-system/profiles/self-hosting-test.nix` — remove `sandbox = false` override
- `openspec/specs/namespace-sandboxing/spec.md` — updated requirements for per-path mode
