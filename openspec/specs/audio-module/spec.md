## ADDED Requirements

### Requirement: Audio module exists independently of graphics
The system provides an `/audio` module at `nix/redox-system/modules/audio.nix` that controls the `audiod` daemon and audio-related configuration without requiring graphics to be enabled.

#### Scenario: Audio enabled without graphics
- **WHEN** a profile sets `/audio.enable = true` and `/graphics.enable = false`
- **THEN** the `audiod` service appears in the generated init scripts and starts during boot

#### Scenario: Audio disabled by default
- **WHEN** no profile sets `/audio.enable`
- **THEN** the default is `false` and no `audiod` service is generated

### Requirement: Audio module owns the audiod service
The `audiod` service entry is computed by `audio.nix` via a `services` option using the shared `serviceType`, following the same pattern as `networking.services`, `graphics.services`, and `iroh.services`.

#### Scenario: Service merged into init scripts
- **WHEN** `/audio.enable = true` and `/hardware.audioEnable = true`
- **THEN** `init-scripts.nix` merges `inputs.audio.services` and the audiod service gets a numbered init script via topological sort

#### Scenario: Graphics module no longer emits audiod
- **WHEN** the graphics module computes its services
- **THEN** the `audiod` entry is absent from `graphics.services` regardless of `hardware.audioEnable`

### Requirement: Audio without hardware drivers produces assertion
The build module validates that enabling audio without audio hardware drivers is a configuration error.

#### Scenario: Mismatched audio config
- **WHEN** `/audio.enable = true` and `/hardware.audioEnable = false`
- **THEN** the build produces an assertion failure with a message indicating that audio hardware drivers must be enabled

### Requirement: Graphical profile preserves audio behavior
Existing profiles that enable graphics with audio continue working identically.

#### Scenario: Graphical profile
- **WHEN** the graphical profile is used
- **THEN** both `/audio.enable = true` and `/hardware.audioEnable = true` are set, and `audiod` starts during boot as before
