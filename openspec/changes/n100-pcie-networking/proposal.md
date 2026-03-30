## Why

The Intel N100 LattePanda Mu boots Redox with working USB, display, and ACPI,
but NVMe storage and RTL8168 Ethernet are invisible. Both devices sit behind
PCIe bridges on subordinate buses. pcid only scans bus 0, so they never get
drivers. Additionally, smolnetd exits immediately without registering the
network stack — even if the NIC driver loaded, there would be no `net`, `ip`,
or `tcp` schemes.

## What Changes

- **PCIe bridge enumeration**: pcid scans PCIe bridge devices (class 0x06,
  subclass 0x04) on bus 0, reads their secondary/subordinate bus numbers, and
  recursively enumerates devices on those buses. This discovers the RTL8168 and
  NVMe controller.
- **pcid.toml device matching**: Add PCI device ID entries for the N100's
  RTL8168 and NVMe controller so pcid-spawner launches the correct drivers.
- **smolnetd startup fix**: Diagnose and fix why smolnetd exits without
  notifying readiness. Serial log shows: `smolnetd exited without notifying
  readiness`. Likely missing `net:` scheme dependency or driver init failure.
- **Network validation**: End-to-end test of rtl8168d → smolnetd → dhcpd →
  ping on bare metal N100.

## Capabilities

### New Capabilities
- `pcie-bridge-enumeration`: pcid discovers and enumerates devices behind PCIe bridges on subordinate buses
- `n100-network-bringup`: RTL8168 driver loads, smolnetd registers network stack, DHCP acquires a lease

### Modified Capabilities

## Impact

- `nix/pkgs/system/base.nix` or pcid source patches — PCIe bridge scanning logic
- `nix/redox-system/modules/build/pcid.nix` — device ID table for N100 NIC and NVMe
- `nix/redox-system/modules/build/init-scripts.nix` — smolnetd startup ordering
- `examples/lattepanda-mu/configuration.nix` — network config validation
- NVMe and Ethernet become available on any board with PCIe bridges (not just N100)
