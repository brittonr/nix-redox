## ADDED Requirements

### Requirement: gdbstub cross-compiles for Redox
The build system SHALL cross-compile gdbstub from source for `x86_64-unknown-redox`, producing a `gdbstub` binary. Dependencies: gdb-protocol (already built), redox_syscall.

#### Scenario: Successful build
- **WHEN** `nix build .#gdbstub` is run
- **THEN** the output contains `bin/gdbstub` as an ELF binary for x86_64-unknown-redox

### Requirement: gdbstub available in development profile
The development profile SHALL include gdbstub in system packages alongside strace.

#### Scenario: gdbstub on disk image
- **WHEN** a Redox system boots with the development profile
- **THEN** `/bin/gdbstub` exists and is executable

### Requirement: gdbstub wired into module system
The gdbstub package SHALL have an entry in `extraPkgs` in system.nix so profiles can reference it with `opt "gdbstub"`.

#### Scenario: Profile references gdbstub
- **WHEN** a profile includes `opt "gdbstub"` in systemPackages
- **THEN** gdbstub is included in the disk image
