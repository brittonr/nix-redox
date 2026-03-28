## ADDED Requirements

### Requirement: Top-level lib.redoxSystem export
The flake SHALL expose `lib.redoxSystem` as the primary entry point for building Redox system configurations. It MUST accept `{ modules, pkgs, hostPkgs }` and return a system attrset with `diskImage`, `toplevel`, `rootTree`, `initfs`, `vmConfig`, and `extend`.

#### Scenario: Downstream flake builds a Redox system
- **WHEN** a downstream flake calls `redox.lib.redoxSystem { modules = [ ./my-config.nix ]; pkgs = ...; hostPkgs = ...; }`
- **THEN** the result contains `diskImage`, `toplevel`, `rootTree`, `initfs` derivations

### Requirement: redoxConfigurations flake output
The flake SHALL expose `redoxConfigurations` as a top-level output containing named system configurations (default, minimal, graphical, cloud, self-hosting).

#### Scenario: User lists available configurations
- **WHEN** a user runs `nix flake show` on the Redox flake
- **THEN** the output includes `redoxConfigurations.default`, `redoxConfigurations.minimal`, `redoxConfigurations.graphical`, `redoxConfigurations.cloud`, `redoxConfigurations.self-hosting`

#### Scenario: User builds a named configuration
- **WHEN** a user accesses `redoxConfigurations.default.diskImage`
- **THEN** they receive the same derivation as `packages.redox-default`

### Requirement: flakeModules.default for downstream composition
The flake SHALL expose `flakeModules.default` as a module that downstream flake-parts or adios-flake consumers can import. The module MUST define a `flake.redoxConfigurations` option so downstream flakes can declare Redox systems.

#### Scenario: Downstream flake uses flake module
- **WHEN** a downstream flake imports `redox.flakeModules.default` and sets `redoxConfigurations.myDevice = redox.lib.redoxSystem { ... }`
- **THEN** the configuration is accessible at `config.flake.redoxConfigurations.myDevice`

### Requirement: Template for new projects
The flake SHALL expose `templates.default` containing a minimal `flake.nix` and `configuration.nix` that produces a bootable Redox disk image.

#### Scenario: User initializes from template
- **WHEN** a user runs `nix flake init -t github:user/redox`
- **THEN** the working directory contains a `flake.nix` that imports the Redox flake and a `configuration.nix` with documented options
- **THEN** running `nix build` in that directory produces a Redox disk image
