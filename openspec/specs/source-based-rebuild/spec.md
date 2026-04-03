## ADDED Requirements

### Requirement: Source rebuild compiles packages from Nix expressions
`snix system rebuild --source` SHALL evaluate `configuration.nix`, find a `packageSources` attribute pointing to a Nix file that returns `{ name = derivation; ... }`, build each derivation through the local builder, and activate the resulting manifest with store paths from the built outputs.

#### Scenario: Rebuild with one source package
- **WHEN** `configuration.nix` contains `packageSources = "/etc/redox-system/packages.nix";`
- **AND** `packages.nix` returns `{ hello = derivation { name = "hello"; builder = "/nix/system/profile/bin/bash"; args = ["-c" "mkdir -p $out/bin; echo 'echo hi' > $out/bin/hello"]; system = "x86_64-unknown-redox"; }; }`
- **AND** the user runs `snix system rebuild --source`
- **THEN** the derivation is built and output appears in `/nix/store/`
- **AND** a new generation is created with the `hello` package in the manifest

#### Scenario: Source rebuild preserves boot-essential packages
- **WHEN** `snix system rebuild --source` runs
- **THEN** boot-essential packages (ion, base, snix, uutils, init) remain in the manifest regardless of what `packages.nix` returns

#### Scenario: Mixed source and cache packages
- **WHEN** `configuration.nix` specifies both `packages = ["ripgrep"]` and `packageSources = "/etc/redox-system/packages.nix"`
- **THEN** `ripgrep` is resolved from the binary cache index
- **AND** packages in `packages.nix` are built from source
- **AND** both sets appear in the resulting manifest

### Requirement: Source rebuild dry-run shows build plan
`snix system rebuild --source --dry-run` SHALL evaluate the package set and print which derivations would be built, without executing any builders.

#### Scenario: Dry run lists derivations
- **WHEN** the user runs `snix system rebuild --source --dry-run`
- **THEN** output lists each derivation name and its `.drv` path
- **AND** no builders are executed
- **AND** no generation is created

### Requirement: Source rebuild reports build failures
When a derivation build fails during `--source` rebuild, snix SHALL report the failure with the derivation name and builder stderr, and SHALL NOT create a new generation.

#### Scenario: Build failure aborts rebuild
- **WHEN** a derivation in `packages.nix` has a builder that exits non-zero
- **AND** the user runs `snix system rebuild --source`
- **THEN** snix prints an error identifying the failed derivation
- **AND** no new generation is created
- **AND** the current system manifest is unchanged
