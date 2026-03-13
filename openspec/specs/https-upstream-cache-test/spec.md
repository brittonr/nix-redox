## ADDED Requirements

### Requirement: HTTPS cache test profile
The system SHALL include a test profile that boots Redox with networking and tests HTTPS fetches against `cache.nixos.org`.

#### Scenario: Test profile boots with networking
- **WHEN** the HTTPS cache test VM boots
- **THEN** it acquires a DHCP address and has internet access via QEMU SLiRP

### Requirement: Fetch narinfo over HTTPS
The HTTPS cache test SHALL fetch a narinfo from `https://cache.nixos.org` and parse it successfully.

#### Scenario: Successful narinfo fetch
- **WHEN** the guest runs `snix path-info <known-store-path> --cache-url https://cache.nixos.org`
- **THEN** the command prints the store path, NAR hash, NAR size, and references

#### Scenario: No internet graceful skip
- **WHEN** the guest cannot reach `cache.nixos.org` (DNS failure or timeout)
- **THEN** the test emits `FUNC_TEST:https-narinfo:SKIP:no-internet` instead of FAIL

### Requirement: HTTPS cache test runner
The system SHALL provide an `https-cache-test` runner script and flake app that boots the test VM, monitors serial output, and reports FUNC_TEST results.

#### Scenario: Test runner passes when HTTPS works
- **WHEN** `nix run .#https-cache-test` is run with internet access
- **THEN** it reports PASS for the HTTPS narinfo test

#### Scenario: Test runner reports results
- **WHEN** the test completes
- **THEN** the runner prints pass/fail/skip counts and total time
