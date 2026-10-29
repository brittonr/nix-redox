## ADDED Requirements

### Requirement: Guest-native kernel build produces a Redox store artifact

The validation harness SHALL provide a focused Redox guest workflow that builds the kernel natively from guest-visible sources and records the resulting store path as proof that the artifact was produced on Redox, not only on the host.

#### Scenario: Focused guest-native kernel build succeeds
- **WHEN** the focused validation runs the guest-native kernel build command on Redox
- **THEN** the build completes successfully on the guest
- **AND** the resulting kernel artifact is written to a `/nix/store/` path
- **AND** the capture output records the exact store path and source provenance

### Requirement: Guest-native bootloader build is validated or explicitly blocked with evidence

The same focused validation SHALL either build the bootloader natively on the guest or emit a clear blocked result that records why the bootloader path is not yet proven.

#### Scenario: Guest-native bootloader build succeeds
- **WHEN** the focused validation runs the guest-native bootloader build command on Redox
- **THEN** the build completes successfully on the guest
- **AND** the resulting bootloader artifact is written to a `/nix/store/` path

#### Scenario: Bootloader path remains blocked
- **WHEN** the focused validation cannot yet build the bootloader natively
- **THEN** the run records a blocked verdict with the missing prerequisite or failure reason
- **AND** the evidence shows kernel-native proof separately from the blocked bootloader path

### Requirement: Focused validation leaves durable, auditable evidence

Every guest-native kernel rebuild validation run SHALL create durable capture artifacts that include guest logs, source provenance, commands executed, and PASS/FAIL verdicts.

#### Scenario: Passing run leaves durable capture
- **WHEN** the focused validation passes
- **THEN** the capture directory contains serial or guest logs, metadata, and a machine-readable summary for the kernel-native proof

### Requirement: Guest-produced boot artifacts are consumable by the boot flow

The validation harness SHALL prove that guest-produced kernel and bootloader artifacts can be staged into the existing boot artifact flow, either by a boot-selection smoke test or an equivalent staging proof that exercises the same manifest and copy paths.

#### Scenario: Guest-produced kernel staged for boot selection
- **WHEN** the focused validation selects the guest-produced kernel artifact for the next boot flow
- **THEN** the system accepts the artifact path without requiring a host rebuild
- **AND** the validation records that the produced store path is consumable by boot management

### Requirement: Native system validation executes a three-boot rebuild and rollback

The `native-rebuild-test` workflow SHALL perform exactly three cold firmware boots on one mutable disk: the seed system, the guest-built native system, and the exact previous seed generation. Staged files alone SHALL NOT satisfy this workflow.

#### Scenario: Firmware executes the guest-built artifacts
- **WHEN** the seed guest completes its ordinary offline native system rebuild and boot selection
- **THEN** the harness freezes the seed and native bootloader, kernel, and initfs identities before restarting
- **AND** it stops and waits for the VMM, extracts the selected guest-produced EFI from that same disk's RedoxFS, and installs those bytes into that disk's ESP
- **AND** the next launch starts firmware from the disk rather than injecting a seed bootloader
- **AND** the executing bootloader, kernel, and initfs each emit exactly one identity matching the frozen native artifact identity and differing from the seed identity
- **AND** the running system verifies the selected native generation, hostname, services, drivers, and boot artifacts

#### Scenario: Firmware executes the exact previous generation after rollback
- **WHEN** the native guest exercises rollback and selects the original generation for the next boot
- **THEN** the harness restarts the same disk from the selected seed EFI
- **AND** the third boot emits the original bootloader, kernel, and initfs identities
- **AND** the guest verifies the exact original generation, restored configuration and services, original kernel/initfs bytes, and retained native generation GC roots
- **AND** only this final boot may report successful suite completion

#### Scenario: Invalid boot evidence cannot pass
- **WHEN** a guest assertion fails, completion arrives before the third boot, a restart is missing or out of order, or an executing-artifact identity is missing, duplicated, or incorrect
- **THEN** the workflow fails rather than treating staging or a narrower test filter as successful boot proof
- **AND** the capture retains separate per-boot logs and the combined guest/host assertions

This workflow proves orderly stop/restart durability. Host-assisted ESP installation is part of the test harness, not a production guest ESP installer or a sudden-power-loss guarantee.
