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

The native three-boot flow additionally retains:

- `boot-0-seed.serial.log`, `boot-1-native.serial.log`, `boot-2-rollback.serial.log` — separate serial evidence from each firmware launch
- `boot-0-seed.vmm.log`, `boot-1-native.vmm.log`, `boot-2-rollback.vmm.log` — matching VMM output
- `expected-identities.log` — seed/native artifact identities frozen from the first boot before either restart

For this flow, `serial.log` combines all three guest logs and the host's identity
and restart assertions. `host-monitor.log` retains samples across the launches.

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
- `boot_cycles` — ordered firmware boots with phase, observed bootloader/kernel/initfs identities, and per-boot log metadata; empty for single-boot flows
- `runner`
- `files`

This keeps focused and full proof evidence comparable without custom per-wrapper parsing.

`boot_cycles[*].identities` records every observed identity for each component.
Missing markers remain empty lists; duplicates are retained, not overwritten.
The native host runner checks these identities against its frozen expectations;
the capture parser does not invent identities from staged files or guest phase
names.

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
that a missing-driver build fails before publishing a generation. A successful
run requires three cold firmware boots on the same writable disk:

1. **Seed:** compile and select the native system; persist the original generation,
   byte snapshots, and expected identities before requesting a restart.
2. **Native:** verify the executing guest-built bootloader, kernel, and initfs,
   plus the native generation/configuration; exercise rollback and select the
   exact original generation before requesting another restart.
3. **Rollback:** verify the original executing artifact identities, generation,
   kernel/initfs bytes, restored services/configuration, and retained native GC roots.

`BOOT_PROOF` markers originate in the executing bootloader/kernel and a service
inside the loaded initfs, not the rootfs proof script. The test-only
`/boot.bootProof` option is preserved in `configuration.boot.bootProof` through
Snix's typed manifest so native initfs rebuilding retains the marker service.
Expected native identities are frozen during the first boot, not inferred from
whatever happened to run after the restart.

Before each restart the host stops and waits for the VMM, extracts the selected
EFI file from that disk's RedoxFS, installs those exact bytes into its ESP, and
launches firmware from the disk. QEMU does not inject a seed EFI for this flow.
This is **host-assisted ESP installation**, not a production guest ESP installer.
The guest fsyncs its phase state and boot files before requesting each orderly
stop/restart; this is not a sudden-power-loss durability claim.

Missing/duplicate/wrong runtime identities, guest failures, early completion, or
missing/out-of-order restarts fail the proof. Only the final rollback boot may
complete successfully; filtering output cannot bypass the protocol checks.

The 16 GiB mutable image and native build scratch need host disk space; use
`TMPDIR=/var/tmp` when `/tmp` is memory-backed or small. Capture metadata reports
the exact run verdict; test fixtures alone are not evidence of a successful run.

Completed Cloud Hypervisor proof: `20261029T000233-native-rebuild-test` passes
**135/135**, with zero failures or skips, in 1799 seconds. All three cold firmware
boots use the same writable disk. The native boot executes the frozen guest-built
bootloader/kernel/initfs identities; the rollback boot executes the original seed
identities and restores generation 1, the original manifest/configuration, service
units, and kernel/initfs bytes. The saved native generation remains GC-rooted.

Seed image assembly preserves complete boot package outputs, including
`boot-proof-id`, at the manifest's store paths. Before restart the guest flushes
the active `/etc` tree rather than requiring native-only leaf files: the seed
generation keeps its PCI configuration inside initfs, not under `/etc/pcid.d`.

Capture: `/var/tmp/redox-self-hosting-captures/20261029T000233-native-rebuild-test/`.
It includes per-boot serial/VMM logs, frozen pre-reboot identities, and the standard
summary/excerpt. `latest-success` now records this completed three-boot result for
`native-rebuild-test`, replacing the earlier single-boot 88/88 result.

QEMU disk-UEFI smoke: `20261028T213608-native-rebuild-test` booted the seed EFI
from the ESP and emitted all three executing-artifact identities. Its intentional
`--timeout 15` limit exited 1 with `host_protocol: three-boot proof timed out on
boot 0`; it did not turn a partial cycle into success or update the success index.
Capture: `/var/tmp/redox-self-hosting-captures/20261028T213608-native-rebuild-test/`.
This is a bounded QEMU boot/rejection check, not a completed QEMU three-boot proof.

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

The earlier 84/84 full result predates these stricter assertions and includes
crashing diagnostic binaries. That historical count is not proof of successful
diagnostic execution.

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

Strict full-suite proof: `20261028T211136-self-hosting-test` passes **84/84**, with
zero failures or skips, in 6827 seconds. The count is unchanged, but the two
diagnostic checks now require successful execution: the serial log records
`Direct link binary exit: 0`, `Output: direct link works!`,
`Runtime env binary exit: 0`, `COMPILE_TIME_DIAG_TEST_VAR=hello_from_environ`, and
`RUNTIME_DIAG_TEST_VAR=hello_runtime`. The same run passes native Snix self-build,
execution/evaluation of that binary, source rebuild, and the hostname/inline-file
rebuild cycle.

Capture: `/var/tmp/redox-self-hosting-captures/20261028T211136-self-hosting-test/`.
`latest-success` now records this strict run under `self-hosting-test`.
