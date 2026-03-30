## Context

pcid is Redox's PCI daemon. It scans PCI configuration space, matches device
IDs against a TOML config, and spawns drivers. Currently it only enumerates
bus 0 — devices behind PCIe-to-PCI bridges are invisible.

On the Intel N100 LattePanda Mu, `lspci` under Linux would show the RTL8168
NIC and NVMe controller on buses 1+ behind PCIe root ports. pcid sees ~20
devices on bus 0 (host bridge, GPU, xHCI, MEI, LPSS, etc.) but misses
everything behind bridges.

smolnetd is the userspace TCP/IP stack. It registers `net:`, `ip:`, `tcp:`,
`udp:` schemes. Serial log shows it exits immediately — likely because no
network interface driver registered a scheme for it to bind to.

## Goals / Non-Goals

**Goals:**
- pcid discovers devices on PCIe subordinate buses (behind bridges)
- NVMe SSD detected and `disk:` scheme registered on N100
- RTL8168 NIC detected, rtl8168d spawned, and networking functional
- smolnetd starts and registers network schemes
- DHCP lease acquired on N100 bare metal

**Non-Goals:**
- Hot-plug of PCIe devices
- SR-IOV or advanced PCIe features
- Fixing smolnetd bugs unrelated to driver availability
- Supporting non-ECAM (MMCONFIG) PCI configuration access — we use legacy
  I/O ports (0xCF8/0xCFC) which support buses 0-255

## Decisions

### PCIe bridge enumeration strategy

**Decision**: Patch pcid to scan bridges after bus 0 enumeration.

After the initial bus 0 scan, iterate discovered devices. For any device
with class=0x06 (bridge), subclass=0x04 (PCI-to-PCI bridge):
1. Read the Secondary Bus Number register (offset 0x19)
2. Read the Subordinate Bus Number register (offset 0x1A)
3. Enumerate all devices/functions on the secondary bus
4. Recurse if more bridges are found

This uses the existing PCI config space read mechanism (0xCF8/0xCFC I/O
ports) which already supports the bus number in bits 16-23 of the address.
The BIOS/UEFI firmware has already configured the bridge bus numbers during
POST — we just need to read them.

**Alternative rejected**: ECAM/MMCONFIG access via MCFG ACPI table. More
complex, requires MMIO mapping, and legacy I/O access already works for
the N100's PCI topology.

### smolnetd startup

**Decision**: Investigate smolnetd exit, fix root cause.

smolnetd likely exits because it can't find any network interface schemes
(e.g., `network:` from rtl8168d). Once PCIe enumeration finds the NIC and
rtl8168d registers its scheme, smolnetd should work. The init script ordering
may also need adjustment — smolnetd must start after the NIC driver.

### PCI device ID matching

**Decision**: Boot Linux on the N100, capture `lspci -nn` output, and add
the exact vendor:device IDs to pcid's TOML config.

The RTL8168 has many variants (8168B, 8168C, 8168E, etc.) with different
PCI device IDs. The NVMe controller's ID depends on which SSD is installed.
We need the exact IDs from this specific hardware.

## Risks / Trade-offs

- **Risk**: Bridge bus numbers may not be configured by all UEFI firmware.
  Mitigation: This is extremely unlikely on modern x86 UEFI systems — the
  firmware must configure bridges for Option ROM and EFI driver loading.

- **Risk**: Some bridges may have subordinate bus ranges that overlap or
  are misconfigured. Mitigation: Trust firmware configuration, don't
  reprogram bridges.

- **Risk**: smolnetd exit may have a deeper cause than missing NIC.
  Mitigation: Serial debug output now works — capture full error context.
