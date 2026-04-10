## ADDED Requirements

### Requirement: OpenSSL 3.x cross-compiles for Redox
The build system SHALL cross-compile OpenSSL 3.5.x for `x86_64-unknown-redox` producing static libraries `libssl.a` and `libcrypto.a` with headers.

#### Scenario: Successful static build
- **WHEN** `nix build .#openssl3-redox` is run
- **THEN** the output SHALL contain `lib/libssl.a`, `lib/libcrypto.a`, and `include/openssl/*.h`
- **AND** the libraries SHALL be linked against relibc

#### Scenario: Redox target detected by Configure
- **WHEN** OpenSSL's `Configure` script runs with target `redox-x86_64`
- **THEN** it SHALL recognize the target and produce a valid Makefile
- **AND** use `SIXTY_FOUR_BIT_LONG` and `elf` perlasm scheme

### Requirement: OpenSSL 3.x coexists with OpenSSL 1.x
The `openssl3-redox` package SHALL be a separate derivation from `openssl-redox` (1.1.1). Both SHALL be independently usable as build inputs.

#### Scenario: Both packages build
- **WHEN** both `openssl-redox` and `openssl3-redox` exist in the package set
- **THEN** each SHALL produce its own `lib/` and `include/` directories
- **AND** packages MAY depend on either without conflict (static linking, no symbol collision at build time)
