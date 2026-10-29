# Self-hosting proof artifacts

Self-hosting proof wrappers now write one capture contract for focused and full VM validation flows.

## Entry points

These host-side wrappers create capture artifacts automatically:

- `nix run .#snix-compile-test -- --verbose`
- `nix run .#snix-sandbox-test -- --verbose`
- `nix run .#self-hosting-test -- --verbose`
- `nix run .#kernel-rebuild-test -- --verbose`
- `TMPDIR=/var/tmp nix run .#native-rebuild-test -- --verbose`

Each wrapper creates a timestamped run directory under `/var/tmp/redox-self-hosting-captures/` unless `REDOX_CAPTURE_DIR` overrides it.

## Capture layout

Each run directory uses this layout:

- `meta.txt` — human-readable run metadata and required-file checklist
- `runner.log` — raw host wrapper output
- `serial.log` — guest serial log copied from the VM runner
- `vmm.log` — VMM stdout/stderr when the VM runner produced it
- `host-monitor.log` — host-side VM sidecar log when the wrapper collected it
- `summary.json` — machine-readable run summary
- `excerpt.txt` — short human-readable excerpt for evidence notes

The wrapper may also keep internal helper state such as `.capture-state.json` inside the run directory.

## Summary schema

`summary.json` uses one field set for focused and full proof flows:

- `flow`
- `run_id`
- `started_at`
- `finished_at`
- `duration_seconds`
- `exit_code`
- `verdict`
- `capture_dir`
- `command`
- `git_rev`
- `git_dirty`
- `test_counts`
- `runner`
- `files`

This keeps focused and full proof evidence comparable without custom per-wrapper parsing.

## Latest-success index

Successful proof wrappers refresh these repo files:

- `docs/self-hosting/latest-success.json`
- `docs/self-hosting/latest-success.md`

Failed runs keep their capture directories for debugging but do not replace the latest-success index.

## Notes for evidence and roadmap docs

Use the generated latest-success index when you want the current canonical capture path.
Use archived OpenSpec evidence when you need an exact historical run tied to a specific change.

## Native system proof scope

`native-rebuild-test` boots without networking or a build bridge. It invokes
ordinary `snix system rebuild` with `systemSource`, builds actual guest-native
kernel/UEFI/initfs artifacts, checks generated PCI configuration and real
`/usr/lib/init.d` units, verifies generation/store/GC-root identities, and checks
that a missing-driver build fails before publishing a generation. Boot-default
consumption and rollback compare the active kernel/initfs and restored service
contents. The existing runner stops after the first completion marker: this is
not a firmware restart or proof that the newly built EFI binary ran from the ESP.

The 16 GiB mutable image and native build scratch need host disk space; use
`TMPDIR=/var/tmp` when `/tmp` is memory-backed or small. Capture metadata reports
the exact run verdict; test fixtures alone are not evidence of a successful run.

## Direct rustc and environment checks

The self-hosting profile's `rustc-direct-link` and `environ-diag` checks compile
native Rust binaries through `/nix/system/profile/bin/cc`, which supplies CRT
startup objects and libc. Standalone rustc does not inherit Cargo's linker
configuration. Using bare `ld.lld` previously emitted binaries without `_start`;
those binaries crashed even though compilation returned success.

Both checks require a zero runtime exit status and exact expected stdout.
`environ-diag` compiles with `DIAG_TEST_VAR=hello_from_environ`, then runs the
same binary with `DIAG_TEST_VAR=hello_runtime`. Its output must contain the
compile-time `env!()` value and the distinct runtime `std::env::var()` value.
Compilation alone is not an environment-propagation PASS.

The recorded 84/84 full run predates these stricter assertions and includes
crashing diagnostic binaries. Keep that historical count separate from a
focused verification of the corrected probes.

Focused proof: `20261028T205624-runtime-environment-smoke` passes 5/5 with no
failures or skips. The two unchanged test names pass with exit 0 and expected
output. Three throwaway negative cases prove that direct-link and environment
probes reject exit 7 even when stdout matches, and that the environment probe
rejects an incorrect runtime value despite exit 0. The cases compile real Rust
binaries in the guest; they do not substitute mocked compiler output.

Capture: `/var/tmp/redox-self-hosting-captures/20261028T205624-runtime-environment-smoke/`.
It retains `probe.nix` (the focused image expression that extracts the current
profile probes), serial output, the runner log, and the standard summary.
`latest-success` records this as a separate flow, not a new full-suite result.
