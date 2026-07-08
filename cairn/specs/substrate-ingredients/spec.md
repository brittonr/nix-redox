# Substrate Ingredients Specification

## Purpose

Defines the `substrate-ingredients` capability.

## Requirements

### Requirement: Redox substrate manifest [r[substrate-ingredients.redox-substrate-manifest]]

Redox MUST expose a documented substrate manifest for external system-layer consumers. The manifest MUST describe the Redox substrate schema version, package/runtime ingredients, builder entrypoints, VM runner capabilities, supported primitive families, and provenance metadata.

The manifest MUST be consumable without importing private Redox flake-module or package-internal files.

#### Scenario: Manifest exposes ingredients [r[substrate-ingredients.redox-substrate-manifest.scenario.ingredients]]

- GIVEN an external consumer evaluates the public Redox substrate surface
- WHEN it reads the manifest
- THEN the manifest MUST include schema version, Redox target identity, available package/runtime ingredients, builder entrypoints, and provenance fields
- AND the consumer MUST NOT need to import private files under `nix/flake-modules` or package implementation directories

#### Scenario: Missing ingredient is explicit [r[substrate-ingredients.redox-substrate-manifest.scenario.missing]]

- GIVEN a requested primitive or builder entrypoint is not available
- WHEN a consumer inspects the manifest or asks the builder shell to use it
- THEN the result MUST fail with a diagnostic naming the missing ingredient
- AND it MUST NOT silently substitute a different runtime or profile

### Requirement: Redox native primitives [r[substrate-ingredients.redox-native-primitives]]

Redox MUST expose pure validation and normalization helpers or data schemas for native substrate primitive plans. At minimum the primitive families SHOULD cover services, users/groups, networking, filesystem layout entries, activation/status hooks, and image materialization inputs.

Primitive validation MUST reject malformed values before invoking image builders.

#### Scenario: Valid primitive plan normalizes [r[substrate-ingredients.redox-native-primitives.scenario.valid]]

- GIVEN a primitive plan with one service, one filesystem entry, and one networking declaration
- WHEN primitive validation runs
- THEN the plan MUST normalize deterministically
- AND the normalized result MUST be suitable for the builder shell

#### Scenario: Malformed primitive rejected [r[substrate-ingredients.redox-native-primitives.scenario.invalid]]

- GIVEN a primitive plan with an invalid service argv or filesystem path
- WHEN primitive validation runs
- THEN validation MUST fail before any builder is invoked
- AND the diagnostic MUST name the invalid primitive field
