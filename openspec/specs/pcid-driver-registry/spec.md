## pcid-driver-registry

Every driver enum value in `hardware.nix` must have a corresponding PCI
match entry in `pcid.nix`, or an explicit ISA/manual spawn mechanism.

### Requirements

- [REQ-PCID-RTL8168] `rtl8168d` has PCI match entries for Realtek
  RTL8168/8111 (vendor 0x10EC, device 0x8168) and RTL8101/8102
  (vendor 0x10EC, device 0x8136), class 0x02 (network).

- [REQ-PCID-SB16-DOC] `sb16d` is documented as ISA-only (no PCI ID).
  A comment in pcid.nix explains this. SB16 is excluded from the
  pcid registry and needs manual spawning via init script when selected.

- [REQ-PCID-COMPLETE] Every entry in the `storageDriver`,
  `networkDriver`, `graphicsDriver`, and `audioDriver` enums in
  `hardware.nix` either has a pcid.nix entry or is documented as
  requiring a different spawn mechanism.

### Tests

- Artifact test: rootTree with rtl8168d selected has a pcid.d TOML
  containing vendor 0x10EC.
- Eval test: system with all declared drivers evaluates without error.
