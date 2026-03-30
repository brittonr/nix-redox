## Why

The GMKtec NucBoxG3 Plus (Intel N150) and other Alder Lake-N mini PCs ship with the Intel I226-V 2.5GbE Ethernet controller [8086:125c]. Redox has no driver for the igc family — the existing `e1000d` only covers legacy E1000 device IDs (0x1004, 0x100e, 0x100f, 0x109a, 0x1503). The I225/I226 uses a different register set and cannot be driven by e1000d. Bare metal Redox boots and runs on this hardware (keyboard, display, NVMe all work) but has zero network connectivity.

## What Changes

- New `igcd` network driver for Intel I225/I226 2.5GbE controllers (igc family)
- Port the hardware abstraction layer from FreeBSD's `sys/dev/igc/` (BSD-3-Clause, ~350KB C)
- Implement the Redox `NetworkAdapter` trait using `driver-network` crate (same pattern as e1000d, rtl8168d, ixgbed)
- Register as a pcid-spawner driver matching PCI class 0x02 with the I225/I226 device IDs
- Add `igcd` to the hardware module's `networkDriver` enum and PCI registry in `pcid.nix`
- Wire into the Nix build system as a cross-compiled Redox package

## Capabilities

### New Capabilities
- `igc-driver`: Intel I225/I226 (igc) 2.5GbE network driver for Redox — PCI init, DMA ring setup, packet TX/RX, link management, interrupt handling

### Modified Capabilities
<!-- No existing specs change — this is a new driver alongside existing ones -->

## Impact

- **New crate**: `drivers/net/igcd/` in the base repo (or standalone in this repo's build)
- **Reference code**: FreeBSD `sys/dev/igc/` — 20 files, BSD-3-Clause. Core HAL files (`igc_mac.c`, `igc_phy.c`, `igc_nvm.c`, `igc_i225.c`, `igc_base.c`, `igc_api.c`) are pure hardware register manipulation with minimal OS dependencies. The main driver file (`if_igc.c`) and TX/RX path (`igc_txrx.c`) need rewriting for Redox's scheme daemon model.
- **Existing Redox reference**: `e1000d` (458 lines Rust) demonstrates the pattern — `pcid_interface::pci_daemon`, BAR mapping, DMA allocation via `common::dma::Dma`, `NetworkAdapter` trait impl, IRQ handling via `EventQueue`
- **Shared infrastructure**: `driver-network` crate (389 lines) provides `NetworkScheme` boilerplate — scheme registration, handle management, blocked read queuing, fevent notifications. The new driver only needs to implement `NetworkAdapter` (4 methods: `mac_address`, `available_for_read`, `read_packet`, `write_packet`).
- **Build system**: `pcid.nix` PCI registry needs igcd entries; `hardware.nix` needs `igcd` in the `networkDriver` enum; new package derivation in `flake.nix`
- **Supported device IDs**: 0x15F2 (I225-LM), 0x15F3 (I225-V), 0x125B (I226-LM), 0x125C (I226-V), 0x125D (I226-IT), and others from the igc family
- **Test hardware**: GMKtec NucBoxG3 Plus with Intel I226-V [8086:125c], accessible via JetKVM
