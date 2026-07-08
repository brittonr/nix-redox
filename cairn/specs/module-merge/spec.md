# Module Merge Specification

## Purpose

Defines the `module-merge` capability.

## Requirements

### Requirement: Adios compatibility boundary [r[module-merge.adios-compatibility-boundary]]

Existing Redox Adios modules and path-keyed profile composition MAY remain an internal implementation and native development workflow. They MUST NOT be the required external system-layer API for OnixOS substrate consumers.

If Redox internally converts substrate primitive plans into Adios path-keyed options, that conversion MUST remain behind the public substrate builder shell and MUST preserve primitive validation diagnostics and provenance.

#### Scenario: External consumer avoids Adios modules [r[module-merge.adios-compatibility-boundary.scenario.external-avoids-adios]]

- GIVEN an external OnixOS substrate consumer builds a Redox artifact
- WHEN it uses the public substrate manifest and builder shell
- THEN it MUST NOT need to construct path keys such as `"/environment"` or `"/services"`
- AND it MUST NOT need to know Adios profile merge rules

#### Scenario: Internal bridge preserves validation [r[module-merge.adios-compatibility-boundary.scenario.bridge-validation]]

- GIVEN the builder shell internally maps a validated primitive plan into current Adios options
- WHEN an unsupported or malformed primitive is present
- THEN the public diagnostic MUST name the primitive field
- AND it MUST NOT expose an opaque Adios merge failure as the only error
