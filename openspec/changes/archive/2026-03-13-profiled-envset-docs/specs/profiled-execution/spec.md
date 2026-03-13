## ADDED Requirements

### Requirement: store-path-execution-test
The scheme-native test suite must verify that a package binary installed while
daemons are running can be executed via its store path.

#### Scenario: rg installed with stored+profiled running
- **WHEN** `snix install ripgrep` completes and `rg_store_path` is discovered
- **THEN** `$rg_store_path/bin/rg --version` exits 0 and output contains "ripgrep"

### Requirement: scheme-file-read-test
The scheme-native test suite must verify that stored can serve binary file
content for a dynamically-installed package through the `store:` scheme.

#### Scenario: read rg binary bytes through store scheme
- **WHEN** ripgrep is installed and stored has loaded its manifest
- **THEN** `cat /scheme/store/{hash}-ripgrep/bin/rg | wc -c` returns a byte count > 0

### Requirement: skip-reason-documented
The old filesystem-profile execution test path must be replaced with a comment
explaining why `/nix/var/snix/profiles/default/bin/rg` does not exist when
profiled is running as a scheme daemon.

#### Scenario: test review
- **WHEN** reading the test file
- **THEN** a comment explains the scheme-vs-filesystem distinction for profile paths
