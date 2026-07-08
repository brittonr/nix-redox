# Design: Redox substrate build reproducibility

## Goal

Turn the successful temporary OnixOS Redox VM artifact build into a reproducible Redox-owned substrate build path.

## Build boundary

The Redox repo remains the owner of kernel, initfs, RedoxFS, package/vendoring, disk image, and VM runner construction. The check must consume the public `redoxSubstrate` value and must not require consumers to import private package files or patch package definitions in `/tmp`.

The first implementation pass should keep the proof path narrow:

1. evaluate the public substrate manifest;
2. normalize a primitive plan with one boot receipt service and one status file;
3. build the Redox kernel, initfs, RedoxFS image, disk image, and QEMU runner;
4. optionally run QEMU in a manually gated check; and
5. emit artifact refs/provenance sufficient for an OnixOS harness to verify the guest receipt.

## Fixed-output inputs

Infrastructure packages used by the substrate proof must carry current fixed-output hashes and deterministic source/vendor construction. Certificate inputs for fetches should come from derivation inputs such as `cacert` rather than operator shell state. If a fetch still requires an external environment value, the derivation or check must fail with a diagnostic naming the missing certificate configuration.

## Test strategy

Use a small positive fixture that exercises the public substrate surface and builds at least through artifact planning in default checks. If the full build or QEMU run is too heavy, expose it as a manual check or app with a stable command and a receipt file. Negative coverage should include stale hash fixtures, missing ingredient lookup, private-internal import attempts, malformed service argv, and unsupported primitive requests.

## Evidence boundary

A passing reproducibility check proves only that Redox can materialize the primitive plan through checked-in Redox builders. OnixOS runtime status, deploy, activation, physical install, rollback, and power-loss claims remain separate OnixOS evidence rows.
