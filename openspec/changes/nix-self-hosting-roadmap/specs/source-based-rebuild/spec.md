## MODIFIED Requirements

### Requirement: Source rebuild compiles packages from Nix expressions
`snix system rebuild --source` SHALL evaluate `configuration.nix`, find a `packageSources` attribute pointing to a Nix file that returns `{ name = derivation; ... }`, build each derivation through the local builder, and activate the resulting manifest with store paths from the built outputs.

When both `--source` and `--cache-url` are provided, cache-resolved packages SHALL be fetched from the remote cache, and source-specified packages SHALL be built locally. The two sets are merged in the final manifest.

#### Scenario: Rebuild with one source package
- **WHEN** `configuration.nix` contains `packageSources = "/etc/redox-system/packages.nix";`
- **AND** `packages.nix` returns a single derivation for `hello`
- **AND** the user runs `snix system rebuild --source`
- **THEN** the derivation is built and output appears in `/nix/store/`
- **AND** a new generation is created with the `hello` package in the manifest

#### Scenario: Source rebuild preserves boot-essential packages
- **WHEN** `snix system rebuild --source` runs
- **THEN** boot-essential packages (ion, base, snix, uutils, init) remain in the manifest regardless of what `packages.nix` returns

#### Scenario: Mixed source and remote cache packages
- **WHEN** `configuration.nix` specifies both `packages = ["ripgrep"]` and `packageSources`
- **AND** `--source --cache-url http://host:port` are provided
- **THEN** `ripgrep` is fetched from the remote cache
- **AND** packages in `packages.nix` are built from source
- **AND** both sets appear in the resulting manifest

#### Scenario: Source build failure reports derivation name
- **WHEN** a derivation from `packages.nix` fails to build
- **THEN** the error message includes the derivation name and builder exit code
- **AND** successfully-built packages from the same set are not lost
