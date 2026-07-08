# Design: Expose Redox substrate ingredients for OnixOS

## Goal

Make Redox consumable as a low-level substrate by OnixOS and Mantle while keeping Redox independent from those frontends. Redox exposes ingredients and native primitive contracts; OnixOS owns system-layer semantics and lowering decisions.

## Public substrate surface

The public consumer surface should be available under `legacyPackages.${system}` or a similarly stable flake output and should include a substrate manifest such as:

```nix
redoxSubstrate = {
  manifest = { schema = "redox-substrate-v1"; ...; };
  packages = { ... };
  builders = {
    mkRootTree = ...;
    mkInitfs = ...;
    mkDiskImage = ...;
    mkVmRunner = ...;
  };
  primitives = {
    service = ...;
    user = ...;
    networking = ...;
    filesystemEntry = ...;
  };
};
```

The exact names can change during implementation, but the responsibilities should remain stable: external consumers discover substrate capabilities and pass substrate-native plans to builder entrypoints without importing private Redox internals.

## Functional core

The implementation should split pure data behavior from build shells:

- pure substrate manifest construction from known package/build capabilities;
- pure primitive validation/normalization for services, users, networking, filesystem layout, and status hook plans;
- pure conversion from primitive plans to current internal Redox build inputs;
- shell code that invokes existing Nix builders, RedoxFS/image tools, and VM runner derivations.

## Adios compatibility boundary

Existing Redox Adios modules and profiles may remain the native development implementation. They should not be the required external API for OnixOS. If a compatibility bridge converts primitive plans into current Adios path-keyed options, that bridge is an internal shell and must not leak as the system-layer contract.

## Service primitives

OnixOS lowering needs argv-preserving service declarations because raw shell strings lose command identity and quoting boundaries. Redox should expose a native service primitive with at least:

- service name;
- description;
- command path or package command identity;
- structured argv;
- service type/init phase;
- enable flag;
- dependency ordering;
- environment variables.

Legacy `args = "..."` in existing Redox profiles remains supported internally.

## Networking primitives

OnixOS lowering needs Redox networking primitives that can represent DNS nameservers, search domains, hostnames, IPv4/IPv6 literals, and static address prefix forms. Runtime support may be partial at first, but unsupported fields must fail clearly rather than be discarded.

## Materialization path

The eventual path is:

```text
OnixOS descriptor
  -> Redox substrate primitive plan
  -> Mantle materialization using Redox ingredients
  -> Redox artifact (kernel/initfs/rootfs/disk image)
```

A Nix-backed substrate builder can remain the development/bootstrap implementation while Mantle materialization matures. Evidence must distinguish Nix-bootstrap development artifacts from Mantle/no-Nix-runtime supported artifacts.
