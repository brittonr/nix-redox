# Tasks: Redox substrate build reproducibility

## Reproducible inputs

- [x] [serial] Refresh stale fixed-output source/vendor hashes for substrate infrastructure packages used by the VM proof r[system-builder.redox-substrate-reproducible-vm-build]
- [x] [serial] Move fixed-output fetch certificate handling into derivation/check inputs or emit a deterministic missing-certificate diagnostic r[system-builder.redox-substrate-reproducible-vm-build]
- [x] [parallel] Add negative coverage for stale fixed-output hashes or missing certificate configuration r[testing.redox-substrate-reproducibility-coverage]

## Repo-owned proof path

- [x] [serial] Add a checked-in primitive-plan fixture that consumes only `legacyPackages.${system}.redoxSubstrate` r[substrate-ingredients.redox-substrate-proof-ingredients]
- [x] [serial] Add a reproducible artifact build target for kernel, initfs, RedoxFS, disk image, and QEMU runner outputs r[system-builder.redox-substrate-reproducible-vm-build]
- [x] [parallel] Add positive coverage that the fixture builds or plans all required artifact families without private imports r[testing.redox-substrate-reproducibility-coverage]
- [x] [parallel] Add negative coverage for private package imports, malformed service argv, missing ingredients, and unsupported primitive requests r[testing.redox-substrate-reproducibility-coverage]

## Documentation and evidence

- [x] [serial] Document the manual real-QEMU proof command, expected outputs, cleanup boundary, and non-claims r[documentation.redox-substrate-reproducible-proof]
- [x] [serial] Run Redox focused substrate checks and Cairn validation/gates r[testing.redox-substrate-reproducibility-coverage]
