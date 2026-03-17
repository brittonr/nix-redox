## Why

Comparing our Nix module system output against the upstream Redox OS book
reveals several gaps where the system we produce diverges from what Redox
expects. Some are silent failures (drivers declared but never spawned),
some are missing standard files, and some are missing packages that the
documentation assumes are present.

We already fixed the two biggest issues in prior commits (/tmp permissions,
home directory ownership, sudo scheme daemon). This change addresses the
remaining gaps found by auditing the book against our build output.

## What Changes

Fill in missing system configuration, driver registration, and default
files that upstream Redox expects. Each fix is small and independent —
they share a common theme (our build doesn't match what the docs say)
but don't depend on each other.

## Capabilities

### New Capabilities

- `pcid-driver-registry`: Add missing PCI match entries for declared hardware
  drivers (rtl8168d, sb16d) so pcid-spawner can actually spawn them.
- `default-etc-files`: Generate standard /etc files that upstream expects
  (/etc/motd, /etc/shells) and that programs like `login` look for.
- `default-profile-packages`: Include documented system tools (contain,
  pkgutils) in the development profile so users have the tools the book
  references.

### Modified Capabilities

None.

## Scope

In scope:
- Missing pcid.d entries for drivers we already declare and build
- Missing /etc/motd and /etc/shells defaults
- Missing packages in development profile (contain, pkgutils)
- Tests for each fix

Out of scope:
- Splitting pcid config between initfs/rootfs boot phases (architectural)
- Building more uutils applets (requires relibc work)
- acid/resist test suite packages (separate effort)
