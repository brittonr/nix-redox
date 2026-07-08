# Tasks: Expose Redox substrate ingredients for OnixOS

## Substrate surface

- [x] [serial] Add a Redox substrate manifest exposing schema version, package/runtime ingredients, builder entrypoints, runner capabilities, and provenance metadata r[substrate-ingredients.redox-substrate-manifest]
- [x] [serial] Add pure validation/normalization helpers for Redox substrate primitive plans before invoking existing Nix builders r[substrate-ingredients.redox-native-primitives]
- [x] [serial] Add a compatibility shell that can feed validated substrate primitive plans into current Redox root-tree/initfs/disk-image construction without exposing Adios modules as the external contract r[system-builder.substrate-builder-shell]
- [x] [serial] Keep Adios path-keyed modules as an internal/native compatibility boundary rather than the external OnixOS substrate contract r[module-merge.adios-compatibility-boundary]

## Native primitives

- [x] [parallel] Add argv-preserving Redox service primitives and deterministic rendering while preserving legacy profile `args` behavior internally r[services.redox-service-primitives]
- [x] [parallel] Add Redox networking primitives for DNS search domains, hostnames, IPv6 literals, and prefix-length static addresses r[networking.redox-network-primitives]
- [x] [parallel] Document the OnixOS/Redox substrate boundary, Redox-owned runtime caveats, and Mantle/no-Nix evidence distinctions r[documentation.redox-substrate-contract]

## External consumer coverage

- [x] [serial] Add a substrate-consumer fixture that builds or evaluates a minimal Redox artifact from the public substrate manifest and primitive plans r[testing.redox-substrate-compatibility]
- [x] [serial] Add negative fixture coverage for malformed service argv, unsupported networking fields, missing substrate ingredients, and accidental private-internal imports r[testing.redox-substrate-compatibility]
- [x] [serial] Run focused substrate manifest, primitive validation, builder-shell, service, networking, and Cairn validation checks and capture evidence before archive r[testing.redox-substrate-compatibility]
