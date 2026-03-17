## Context

Audit of the upstream Redox OS book against our Nix build output revealed
gaps in three areas: missing PCI driver registry entries, missing default
/etc files, and missing packages in profiles. All fixes are independent
and low-risk.

## Goals / Non-Goals

**Goals:**
- Every driver declared in `hardware.nix` has a corresponding pcid entry
- Standard /etc files that upstream programs expect are generated
- Development profile includes tools the Redox book documents

**Non-Goals:**
- Splitting pcid config between initfs/rootfs phases (architectural change)
- Building more uutils applets (relibc compatibility work)
- Packaging acid/resist test suites (separate effort)

## Decisions

**pcid entries**: Add vendor/device match rules for RTL8168 and SB16 to
`pcid.nix`. These are the standard PCI IDs for these devices. Without
them, pcid-spawner silently ignores the hardware even when the driver
binary is present.

**RTL8168 PCI IDs**: Realtek uses vendor 0x10EC. The RTL8168 family
covers device IDs 0x8168 (RTL8168/8111) and 0x8136 (RTL8101/8102).
Both match class 0x02 (network).

**SB16 PCI ID**: Creative SoundBlaster16 uses ISA, not PCI. However,
QEMU's `-soundhw sb16` uses ISA port I/O at 0x220. The pcid-spawner
only handles PCI devices. SB16 needs a different spawning mechanism
(manual init script or ISA probe). For now, document this limitation
and add an init script for sb16d when the driver is selected.

**Default /etc/motd**: Generate a simple welcome message. The `login`
binary from userutils reads and displays this. Make the text
configurable via the environment module.

**/etc/shells**: List available login shells. Standard Unix convention.
Generated from the shells actually present in the system.

**Profile packages**: Add `contain` and `pkgutils` to the development
profile using the existing `opt` pattern (graceful if not built).

## Risks / Trade-offs

Low risk overall. The pcid entries are passive — they only activate when
matching hardware is present. The /etc files are read-only defaults.
Adding packages to the development profile uses the existing `opt`
pattern that skips missing packages.

The SB16 ISA limitation is a known gap. Documenting it is better than
adding a broken pcid entry.
