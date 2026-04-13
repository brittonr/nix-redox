## MODIFIED Requirements

### Requirement: Rebuild applies configuration changes to the running system
`snix system rebuild` SHALL evaluate `configuration.nix`, resolve packages from the binary cache (local or remote), build any source-specified packages locally, and activate the result. The rebuild flow SHALL:

1. Evaluate `/etc/redox-system/configuration.nix` into a `RebuildConfig` attrset
2. Merge the config with the current manifest, preserving boot-essential packages
3. Resolve package names to store paths — trying remote cache first (if `--cache-url` provided), then local cache, then source build (if `--source` and `packageSources` specified)
4. Download and extract any remote NARs to `/nix/store/`
5. Build any source-specified packages via the local builder
6. Generate etc files and init scripts from the merged manifest
7. Create a new generation before activation
8. Activate: update profile symlink, write etc files, restart changed services
9. Report whether reboot is recommended (boot component changes)

#### Scenario: Rebuild with package addition from remote cache
- **WHEN** configuration.nix adds `"helix"` to `packages`
- **AND** `--cache-url http://10.0.2.2:8080` is provided
- **AND** the remote cache has helix
- **THEN** helix is downloaded, extracted, and linked into the profile
- **AND** a new generation is created
- **AND** `hx --help` works after rebuild

#### Scenario: Rebuild with source package
- **WHEN** configuration.nix specifies `packageSources = "/etc/redox-system/packages.nix"`
- **AND** `--source` flag is provided
- **AND** packages.nix returns a derivation for `my-tool`
- **THEN** `my-tool` is built from source via the local builder
- **AND** the output appears in the profile

#### Scenario: Rebuild with mixed cache and source packages
- **WHEN** configuration.nix lists both `packages = ["ripgrep"]` and `packageSources`
- **THEN** ripgrep is resolved from the cache
- **AND** source packages are built locally
- **AND** both appear in the resulting manifest

#### Scenario: Rebuild with hostname change
- **WHEN** configuration.nix changes `hostname` to `"my-redox"`
- **AND** `snix system rebuild` runs
- **THEN** `/etc/hostname` contains `my-redox`
- **AND** `snix system info` reports the new hostname

#### Scenario: Reboot recommended after boot path change
- **WHEN** the new manifest's boot components differ from the current running system
- **THEN** `reboot_recommended` is true in the activation result
- **AND** the user is informed that a reboot is needed

#### Scenario: Rebuild without network uses local cache only
- **WHEN** `snix system rebuild` runs without `--cache-url`
- **THEN** packages are resolved from `/nix/cache` only
- **AND** unresolvable packages produce a clear error

### Requirement: Rebuild creates a generation before activation
`snix system rebuild` SHALL create a numbered generation under `/etc/redox-system/generations/` containing the new manifest and metadata BEFORE activating. If activation fails, the generation remains but is not set as current.

#### Scenario: Generation created on successful rebuild
- **WHEN** rebuild succeeds
- **THEN** a new directory exists at `/etc/redox-system/generations/N/`
- **AND** it contains `manifest.json` and `metadata.json`
- **AND** `/nix/system/current` symlink points to generation N

#### Scenario: Generation preserved on activation failure
- **WHEN** rebuild creates generation N but activation fails (e.g., broken service script)
- **THEN** generation N's directory exists with its manifest
- **AND** `/nix/system/current` still points to the previous generation
