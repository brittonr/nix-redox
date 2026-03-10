## ADDED Requirements

### Requirement: Test cache includes ripgrep
The test binary cache SHALL include the cross-compiled ripgrep package alongside mock-hello.

#### Scenario: Cache build produces ripgrep narinfo
- **WHEN** `test-binary-cache.nix` is built
- **THEN** the output directory contains a `.narinfo` file for ripgrep and a corresponding `.nar.zst` file

#### Scenario: packages.json lists ripgrep
- **WHEN** the cache's `packages.json` is read
- **THEN** it contains an entry for `ripgrep` with storePath, pname, version, narSize, and fileSize fields

### Requirement: Network install test verifies ripgrep
The network install test SHALL install ripgrep from the HTTP cache and verify it executes.

#### Scenario: ripgrep installs from remote cache
- **WHEN** the guest runs `snix install ripgrep --cache-url http://10.0.2.2:18080`
- **THEN** the ripgrep binary appears in the profile at `/nix/var/snix/profiles/default/bin/rg`

#### Scenario: ripgrep executes after install
- **WHEN** the guest runs `/nix/var/snix/profiles/default/bin/rg --version`
- **THEN** the command produces output containing `ripgrep`

#### Scenario: All existing mock-hello tests still pass
- **WHEN** the network install test runs
- **THEN** all 8 existing tests (net-dhcp, net-connectivity, net-search, net-install, net-install-runs, net-store-path, net-install-idempotent, net-show) still pass
