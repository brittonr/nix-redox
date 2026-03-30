## Context

Redox network drivers follow a consistent pattern: a thin main.rs that uses `pcid_interface::pci_daemon` for PCI setup, maps BARs, and constructs a `NetworkScheme` from the `driver-network` crate. The driver-specific code lives in a `device.rs` that implements the `NetworkAdapter` trait (4 methods). The existing `e1000d` driver is 458 lines total.

The Intel I225/I226 (igc) hardware is a 2.5GbE PCIe NIC with a register interface that shares ancestry with E1000 but differs in descriptor formats, PHY management, and initialization sequences. FreeBSD has a complete igc driver at `sys/dev/igc/` (BSD-3-Clause, ~350KB C across 20 files). The HAL layer (mac, phy, nvm, i225, base, api) is portable C with minimal OS coupling — it reads/writes registers through function pointers in `igc_hw`.

Test hardware: GMKtec NucBoxG3 Plus (Intel N150) with I226-V [8086:125c], accessible via JetKVM for remote boot/debug.

## Goals / Non-Goals

**Goals:**
- Basic packet TX/RX on Intel I225/I226 at line rate (2.5 Gbps)
- Support the device IDs found on Alder Lake-N mini PCs: I226-V (0x125C), I226-LM (0x125B), I225-V (0x15F3), I225-LM (0x15F2)
- Integrate with Redox's smolnetd for TCP/IP stack
- Follow existing driver conventions (pcid-spawner, driver-network, DMA, IRQ)

**Non-Goals:**
- Advanced features: TSO, RSS, VLAN offload, PTP timestamping, EEE
- WiFi (the RTL8852BE on the GMKtec is a separate problem)
- Performance tuning beyond functional correctness
- Supporting every I225/I226 variant (start with what we can test)

## Decisions

**1. Rewrite in Rust, port the HAL from FreeBSD C**

The FreeBSD igc HAL (`igc_mac.c`, `igc_phy.c`, `igc_nvm.c`, `igc_i225.c`, `igc_base.c`) is ~135KB of C that manipulates hardware registers through accessor functions. We'll translate this to Rust rather than FFI-wrapping C, because:
- Redox's cross-compilation toolchain targets Rust natively
- The HAL is straightforward register read/write logic, not complex algorithms
- Eliminates C build complexity in the Nix build system
- Better integration with Redox's `common::dma::Dma` and `pcid_interface`

**2. Use the same `NetworkAdapter` trait pattern as e1000d**

The `driver-network` crate handles all scheme boilerplate. Our driver only implements:
- `mac_address() -> [u8; 6]`
- `available_for_read() -> usize`
- `read_packet(buf) -> Result<Option<usize>>`
- `write_packet(buf) -> Result<usize>`

This is identical to e1000d's structure and proven to work with smolnetd.

**3. Start with legacy interrupts, upgrade to MSI-X later**

The I226 supports MSI-X (5 vectors per lspci), but e1000d uses legacy interrupts via `pcid_interface` and it works. Start with legacy IRQs for simplicity. MSI-X can be added later for multi-queue support.

**4. Single TX/RX queue initially**

The I226 supports 4 TX and 4 RX queues. Start with queue 0 only, matching e1000d's approach. Multi-queue adds complexity with no benefit until Redox's network stack supports it.

**5. Advanced descriptor format**

The I225/I226 uses advanced TX/RX descriptors (not legacy E1000 descriptors). These provide richer status fields and checksum offload capability. We'll implement the advanced format from the start since that's what the hardware expects.

## Risks / Trade-offs

- **Register compatibility**: The igc register map overlaps with E1000 in some areas (CTRL, STATUS, RAL/RAH, RCTL, TCTL) but diverges in others (descriptor base addresses, interrupt registers, PHY access). Careful translation from FreeBSD source required.
- **PHY initialization**: The I225/I226 has an integrated 2.5GBASE-T PHY that requires a specific init sequence. FreeBSD's `igc_i225.c` handles this. Getting it wrong means no link.
- **NVM access**: The driver needs to read the MAC address from NVM (EEPROM/flash). FreeBSD's `igc_nvm.c` implements this. If NVM access fails, we can fall back to reading from RAL0/RAH0 registers (BIOS typically programs these).
- **DMA coherency**: The I226 uses DMA for descriptor rings and packet buffers. Redox's `common::dma::Dma` handles physical allocation. Must ensure proper cache management and descriptor ownership semantics.
- **Testing scope**: We have exactly one test device (GMKtec I226-V). Other I225/I226 variants may have quirks we can't test.
