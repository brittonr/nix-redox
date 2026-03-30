## ADDED Requirements

### REQ-PCIE-BRIDGE-SCAN

pcid SHALL enumerate PCI devices behind PCIe-to-PCI bridges (class 0x06,
subclass 0x04) by reading the Secondary Bus Number (config offset 0x19)
and scanning all device/function slots on that bus.

### REQ-PCIE-BRIDGE-RECURSE

pcid SHALL recursively enumerate bridges found on subordinate buses,
up to a maximum depth of 8 to prevent infinite loops from misconfigured
firmware.

### REQ-PCIE-BRIDGE-DRIVER-SPAWN

Devices discovered on subordinate buses SHALL be matched against the
pcid TOML configuration and have drivers spawned, identically to bus 0
devices.

### REQ-PCIE-BUS-ADDRESS-FORMAT

PCI device addresses in scheme paths SHALL include the bus number:
`<segment>-<bus>-<device>.<function>` (e.g., `0000-01-00.0`). This is
already the format used by pcid — subordinate bus devices just need
non-zero bus numbers.

### REQ-PCIE-LEGACY-IO

PCIe bridge enumeration SHALL use legacy I/O port configuration access
(0xCF8/0xCFC) with the bus number encoded in bits 23:16 of the config
address. No ECAM/MMCONFIG required.
