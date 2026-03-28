## Context

Redox OS currently boots and tests exclusively in QEMU and Cloud Hypervisor. All hardware drivers (storage, network, USB, display) exist as user-space daemons selected via pcid-spawner based on PCI enumeration. The module system (adios) already supports selecting driver sets per-configuration via `/hardware` options.

The LattePanda Mu is a 60×70mm compute module with an Intel N100 (Alder Lake-N, 4C/4T, up to 3.4 GHz). The DFR1146 variant has 8GB LPDDR5 and 64GB eMMC 5.1. It plugs into the Carrier Lite (DFR1142), a 3.5" board that breaks out:

| Interface | Carrier Lite | Redox Driver | Status |
|-----------|-------------|-------------|--------|
| Storage (eMMC) | SDHCI via SoC | *none* | **No driver** |
| Storage (M.2 M-Key) | PCIe 3.0 x1 NVMe | nvmed | ✅ works |
| Ethernet | Realtek RTL8111 GbE (confirmed) | rtl8168d | ✅ works |
| USB 3.2 | xHCI | xhcid | ✅ works |
| USB 2.0 | xHCI/EHCI | xhcid | ✅ works |
| Display (HDMI 2.0) | Intel UHD (GOP) | vesad | ✅ GOP framebuffer |
| Audio | Intel HDA | ihdad | ✅ works |
| SIO_UART | 3.3V serial terminal header | kernel serial | ✅ debug console |
| Gravity UART | 3.3V peripheral UART | — | secondary |
| WiFi (M.2 E-Key) | depends on card | *none* | **No driver** |
| PCIe x4 slot | full-size slot | depends on card | varies |

The practical boot strategy is to boot from a USB flash drive (for quick iteration) or an M.2 NVMe SSD (for persistent installs). The eMMC and WiFi gaps are documented non-goals.

## Goals / Non-Goals

**Goals:**
- Boot Redox OS on the LattePanda Mu + Carrier Lite to a working shell (serial and/or graphical)
- Validate NVMe storage, RTL8168 networking, xHCI USB, vesad display, and ihdad audio on real hardware
- Produce a Nix configuration profile that builds a correct disk image for this board
- Produce a flash-and-boot runbook with BIOS setup, image flashing, and verification steps
- Capture which PCI device IDs appear on this hardware so pcid-spawner matches correctly

**Non-Goals:**
- eMMC (SDHCI) driver — requires new driver development, separate change
- WiFi — no Redox WiFi stack exists
- Intel GPU native driver — vesad (UEFI GOP) provides a framebuffer, no acceleration
- Suspend/resume, power management, thermal management
- Automated CI on this hardware (future work)

## Decisions

### 1. Boot medium: USB flash drive for bringup, NVMe for persistent

**Rationale**: USB boot works with no hardware changes (just flash and plug in). The UEFI firmware on the Mu supports USB boot natively. Once bringup succeeds, an M.2 2230 NVMe SSD in the Carrier Lite's M-Key slot provides persistent storage at full speed. Both use existing Redox drivers (xhcid for USB boot path, nvmed for NVMe).

**Alternative considered**: eMMC boot — rejected because Redox has no SDHCI driver and writing one is a separate, larger effort.

### 2. Display: vesad (UEFI GOP) not a native Intel GPU driver

**Rationale**: The UEFI firmware initializes the Intel UHD GPU and provides a GOP framebuffer. vesad consumes this framebuffer directly. Resolution is fixed at whatever the firmware selects (typically the HDMI monitor's preferred mode). This is sufficient for Orbital and text console. A native i915-equivalent driver is a multi-month effort and out of scope.

### 3. Network: RTL8168d as the primary Ethernet driver

**Rationale**: The Carrier Lite's Gigabit Ethernet is a Realtek RTL8111 (confirmed by official docs). The rtl8168d driver in Redox handles this family. PCI vendor:device ID 10EC:8168 is already in the pcid registry. No ambiguity here.

### 4. Serial debug via Carrier Lite UART header

**Rationale**: The Carrier Lite has two UART headers: a **SIO_UART** labeled as a "serial port terminal" (3.3V logic) and a Gravity-4P UART for peripherals. The SIO_UART is the debug console — it's routed through the Super I/O chip, which typically provides legacy COM1 (0x3F8). The Redox kernel writes to legacy serial by default, so this should work out of the box with a 3.3V USB-UART cable.

**Risk**: If the SIO_UART is routed via a PCI-based HSUART rather than legacy ISA, kernel serial output won't appear. Mitigation: check BIOS serial port settings, or fall back to HDMI for initial debug.

### 5. Configuration as an example profile, not a new module

**Rationale**: The LattePanda Mu config is just a composition of existing module options — driver selection, disk size, hostname. No new module code is needed. Placing it in `examples/lattepanda-mu/` keeps it consistent with existing examples (minimal, graphical-desktop, dev-workstation).

## Risks / Trade-offs

- **[Ethernet chip mismatch]** → Boot Linux first (or check BIOS PCI list) to confirm the exact NIC chip. Have both rtl8168d and e1000d in the config as fallback.
- **[UART routing]** → If UART header isn't legacy COM1, serial debug won't work out of the box. Mitigation: use HDMI display as primary debug output, document BIOS serial settings.
- **[UEFI GOP resolution]** → vesad takes whatever resolution the firmware provides. If the firmware picks a resolution Orbital can't handle, boot may appear to hang. Mitigation: test with a known monitor, document how to set resolution in BIOS if needed.
- **[NVMe compatibility]** → Some M.2 2230 NVMe SSDs may have quirks. Mitigation: test with a known-good drive (e.g., WD SN740, Samsung PM991).
- **[USB boot reliability]** → UEFI USB boot depends on the firmware's USB driver. Some firmware has bugs with certain USB drives. Mitigation: test with multiple USB drives, document known-good models.
- **[pcid PCI ID gaps]** → The Intel N100 may expose PCI devices with IDs not in the current pcid registry (e.g., HD Audio device ID different from ICH6/ICH9). Mitigation: enumerate PCI devices on the real board and add missing IDs.
