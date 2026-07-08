# Redox substrate surface

Redox exposes a public substrate surface for external system-layer consumers such
as OnixOS and Mantle lowerers. Redox owns kernel, relibc, sysroot, drivers,
RedoxFS, init/initfs, package recipes, image assembly, and VM runner mechanics.
External frontends own roles, settings, providers, lifecycle, status, and other
system-layer semantics.

Redox does **not** depend on OnixOS, onix-modules, Nickel, or Mantle. The current
Adios path-keyed Redox modules remain an internal/native development workflow;
they are not the external OnixOS system contract.

## Public entrypoint

For each supported host system, consumers use:

```nix
redox.legacyPackages.${system}.redoxSubstrate
```

The public value contains:

- `manifest`: data-only schema/version/capability/provenance metadata;
- `primitives.normalizePlan`: pure validation and deterministic normalization;
- `primitives.toModule`: conversion from substrate primitives to the current
  internal Redox compatibility module;
- `builders.evaluateArtifactPlan`: validation-only artifact planning;
- `builders.buildSystem`: compatibility shell that feeds a validated primitive
  plan into Redox root-tree, initfs, disk-image, and VM-runner construction;
- `manifestTools.requireIngredient`: explicit fail-closed ingredient lookup for
  consumers that require a named builder, package family, primitive family, or
  runner capability.

The manifest schema is `redox-substrate-v1`. It describes package/runtime
ingredients, builder entrypoints, runner capabilities, supported primitive
families, and provenance. It is intentionally consumable without importing files
under `nix/flake-modules` or package implementation directories.

## Primitive plan shape

A minimal primitive plan looks like:

```nix
let
  subnetPrefixLength = 64;
in
{
  services.exampled = {
    description = "Example substrate service";
    command = "/bin/exampled";
    argv = [ "--flag" "value with spaces" ];
    type = "nowait";
    wantedBy = "rootfs";
    after = [ "smolnetd" ];
    environment.EXAMPLE_MODE = "substrate";
  };

  networking = {
    enable = true;
    mode = "static";
    hostname = "redox-substrate";
    dns = [ "2001:4860:4860::8888" ];
    searchDomains = [ "svc.example" "example" ];
    defaultRouter = "2001:db8::1";
    interfaces.eth0.addresses = [
      { address = "2001:db8::10"; prefixLength = subnetPrefixLength; gateway = "2001:db8::1"; }
    ];
  };

  filesystem = {
    directories = [ "/srv/example" ];
    files."etc/redox-substrate.txt".text = "hello\n";
  };
}
```

The checked fixture in `examples/substrate-consumer/` uses this shape and imports
only the public substrate value supplied by the caller.

## Compatibility shell

`builders.buildSystem { plan = ...; }` validates the primitive plan, converts it
behind the compatibility boundary, and returns the normal Redox system outputs
such as `rootTree`, `initfs`, `diskImage`, `vmConfig`, `systemChecks`, and
provenance under `substrate`.

Unsupported or malformed inputs fail before image building. Diagnostics name the
substrate primitive field, for example malformed `services.<name>.argv`, unknown
`networking.*` fields, missing manifest ingredients, or filesystem file paths
that conflict with generated Redox system files.

## Runtime caveats

Do not assume POSIX shell behavior, NixOS options, systemd units, Linux
networking tools, or guest-side Onix/Nickel evaluation inside Redox. Ion shell
syntax and Redox schemes differ from POSIX/Linux, and some runtime networking
features may initially be validation-only or compatibility-shell materialized.
When a declared primitive cannot be rendered by the current Redox builder, the
builder must fail clearly rather than silently dropping it.

## Evidence distinction

The current substrate builder is Nix-backed development/bootstrap plumbing. A
successful Nix build proves that Redox can materialize the primitive plan through
its current builders. It does not, by itself, prove Mantle/no-Nix-runtime
support. Mantle evidence must be recorded separately when a Mantle backend lowers
and materializes the same substrate ingredients without relying on Nix at
runtime.
