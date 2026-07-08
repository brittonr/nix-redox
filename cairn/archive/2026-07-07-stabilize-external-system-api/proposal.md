# Proposal: Expose Redox substrate ingredients for OnixOS

## Summary

Expose Redox as a stable low-level substrate for OnixOS and Mantle materialization without making Redox's Adios module system the external system-layer contract. Redox should provide kernel/userspace/image ingredients and native primitive schemas; OnixOS should own roles, settings, providers, services, users, lifecycle, and status semantics.

## Motivation

The desired architecture is:

```text
Nickel/onix-modules
  -> OnixOS descriptor
  -> Mantle materialization graph
  -> Redox kernel/userspace/rootfs/image artifact
```

Redox remains the original Nix-to-Redox prototype and should continue to own the hard low-level work: cross-compilation, relibc/sysroot, drivers, RedoxFS, init/initfs, and image/runner mechanics. But external system configuration should not depend on Redox Adios path-keyed modules. Instead, Redox should expose stable substrate ingredients and native primitive contracts that an OnixOS substrate adapter can target.

## Scope

- Expose a substrate manifest describing Redox package/runtime ingredients, kernel/initfs/rootfs/image builder entrypoints, VM runner capabilities, and version/provenance metadata.
- Expose native primitive schemas for service declarations, users/groups, networking, filesystem layout, activation/status hooks, and image materialization inputs.
- Preserve existing Redox profiles and Adios modules as internal/native development compatibility, but do not present them as the long-term external OnixOS system API.
- Add argv-preserving service primitives and networking fields needed by an OnixOS Redox substrate lowerer.
- Add fixtures that consume the substrate ingredient surface without importing private `nix/flake-modules` internals or relying on Adios path-keyed profile composition.
- Document the boundary between Redox-owned substrate mechanics and OnixOS-owned system semantics.

## Affected specs

- `substrate-ingredients`: manifest and build/materialization ingredient surface.
- `system-builder`: compatibility shell around current Redox system/image builders for substrate inputs.
- `services`: native Redox service primitive contract with structured argv.
- `networking`: native Redox networking primitive contract for OnixOS lowering.
- `documentation`: substrate boundary and caveats.
- `testing`: external substrate-consumer fixtures and negative coverage.

## Non-goals

- Do not make Redox depend on OnixOS, onix-modules, Nickel, or Mantle.
- Do not require Redox to evaluate Onix Nickel/WASM or guest-side `snix` to support Onix evaluation.
- Do not stabilize Redox Adios path-keyed modules as the external OnixOS system-layer API.
- Do not remove existing Redox profiles or native development workflows.
- Do not guarantee all OnixOS provider surfaces are renderable by Redox in this change.

## Verification expectations

The change is complete when external consumers can discover Redox substrate ingredients through a documented surface, validate/render native primitive schemas for first-wave service/network/user/filesystem/status inputs, build or evaluate a minimal Redox substrate artifact without importing private internals, and see clear failures for unsupported or malformed substrate inputs.
