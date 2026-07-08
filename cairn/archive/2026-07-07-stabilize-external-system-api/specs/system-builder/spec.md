## ADDED Requirements

### Requirement: Substrate builder shell [r[system-builder.substrate-builder-shell]]

Redox MUST provide a compatibility builder shell that accepts validated Redox substrate primitive plans and feeds them into Redox root-tree, initfs, disk-image, and VM-runner construction. The builder shell MAY internally reuse existing Adios/profile machinery, but external consumers MUST NOT be required to construct Redox Adios path-keyed modules as the system-layer API.

The builder shell MUST expose enough artifact outputs for OnixOS/Mantle integration, including root tree or root layout identity, initfs when available, disk image when requested, VM config/runner metadata when available, and system checks/provenance.

#### Scenario: Primitive plan builds artifact [r[system-builder.substrate-builder-shell.scenario.build]]

- GIVEN an external consumer passes a validated Redox substrate primitive plan to the public builder shell
- WHEN the builder evaluates
- THEN it MUST produce requested Redox artifact outputs such as root tree, initfs, disk image, or VM runner metadata
- AND the caller MUST NOT need to import private Redox internals or construct Adios profile modules

#### Scenario: Existing profile builds remain compatible [r[system-builder.substrate-builder-shell.scenario.compatible]]

- GIVEN existing Redox flake outputs such as `redox-minimal` and `redox-graphical`
- WHEN the substrate builder shell is added
- THEN those outputs MUST continue to evaluate through existing native development paths
- AND the compatibility shell MUST NOT remove existing profile workflows

#### Scenario: Unsupported primitive fails clearly [r[system-builder.substrate-builder-shell.scenario.unsupported]]

- GIVEN a primitive plan requests a feature the current Redox builder cannot materialize
- WHEN the builder shell validates or evaluates the plan
- THEN evaluation MUST fail with a diagnostic naming the unsupported primitive
- AND it MUST NOT silently drop the primitive
