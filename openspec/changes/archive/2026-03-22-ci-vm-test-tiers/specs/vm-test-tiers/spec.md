## ADDED Requirements

### Requirement: VM tests organized into cost-based sub-tiers
The check system SHALL organize VM tests into three sub-tiers: `tier-vm-fast`, `tier-vm-full`, and `tier-vm-heavy`, each containing tests grouped by execution cost and resource requirements.

#### Scenario: tier-vm-fast contains quick offline tests
- **WHEN** `nix build .#checks.x86_64-linux.tier-vm-fast` is run
- **THEN** it SHALL depend on: boot-test, functional-test, multi-user-test, bridge-test, scheme-daemon-test, iroh-test, scheme-native-test, boot-generation-select-test (8 tests total)

#### Scenario: tier-vm-full adds medium and network tests
- **WHEN** `nix build .#checks.x86_64-linux.tier-vm-full` is run
- **THEN** it SHALL depend on all tier-vm-fast tests plus: rebuild-generations-test, e2e-rebuild-test, network-test, network-install-test, channel-update-test (13 tests total)

#### Scenario: tier-vm-heavy adds expensive tests
- **WHEN** `nix build .#checks.x86_64-linux.tier-vm-heavy` is run
- **THEN** it SHALL depend on all tier-vm-full tests plus: bridge-rebuild-test, self-hosting-test, parallel-build-test (16 tests total)

### Requirement: Backward-compatible tier-vm alias
The existing `tier-vm` check target SHALL remain as an alias for `tier-vm-fast` so that current CI workflows and developer habits continue to work without modification.

#### Scenario: tier-vm resolves to tier-vm-fast
- **WHEN** `nix build .#checks.x86_64-linux.tier-vm` is run
- **THEN** it SHALL build the same set of tests as `tier-vm-fast`

### Requirement: tier-vm-all aggregation target
The check system SHALL provide `tier-vm-all` that depends on all three sub-tiers, running all 16 VM tests.

#### Scenario: tier-vm-all runs everything
- **WHEN** `nix build .#checks.x86_64-linux.tier-vm-all` is run
- **THEN** it SHALL depend on all tests from tier-vm-fast, tier-vm-full, and tier-vm-heavy

### Requirement: All VM tests individually addressable
Each VM test SHALL be individually buildable via `nix build .#checks.x86_64-linux.<test-name>` regardless of tier membership.

#### Scenario: Individual test builds
- **WHEN** `nix build .#checks.x86_64-linux.network-test` is run
- **THEN** it SHALL build and run the network test independently

### Requirement: httpsCacheTest excluded from checks
The httpsCacheTest SHALL NOT be included in any check tier because it requires outbound internet access incompatible with the Nix build sandbox.

#### Scenario: https-cache-test absent from checks
- **WHEN** `nix flake check` is run in a standard Nix sandbox
- **THEN** no check SHALL attempt to reach cache.nixos.org or any external host
