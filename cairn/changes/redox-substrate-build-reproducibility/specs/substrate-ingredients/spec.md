## ADDED Requirements

### Requirement: Redox substrate proof ingredients [r[substrate-ingredients.redox-substrate-proof-ingredients]]

The public Redox substrate manifest SHALL identify the ingredients required for the reproducible VM proof so external consumers can fail closed before image construction.

#### Scenario: Required proof ingredients are discoverable [r[substrate-ingredients.redox-substrate-proof-ingredients.scenario.discoverable]]

- GIVEN an external consumer prepares a Redox VM proof plan
- WHEN it inspects the public substrate manifest
- THEN it MUST be able to discover whether kernel, initfs, RedoxFS, disk image, and QEMU runner ingredients are available
- AND missing ingredients MUST be reported by name before artifact construction begins

#### Scenario: Provenance distinguishes development builders [r[substrate-ingredients.redox-substrate-proof-ingredients.scenario.provenance]]

- GIVEN a reproducible proof uses Nix-backed Redox builders
- WHEN manifest provenance is emitted
- THEN it MUST identify the builder path as Redox-owned bootstrap/development plumbing
- AND it MUST NOT imply guest-side Nix, OnixOS, Nickel, or Mantle runtime support
