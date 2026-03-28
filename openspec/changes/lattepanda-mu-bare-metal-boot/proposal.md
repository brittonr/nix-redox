## Why

Redox OS runs exclusively in VMs today. Booting on real hardware validates that drivers, UEFI boot, and the init system work outside the QEMU/Cloud Hypervisor comfort zone. The LattePanda Mu (N100, 16GB) on the Carrier Lite board is a good first target: it's x86_64 with standard Intel peripherals, small/cheap, has UART for serial debug, and every I/O path (storage, network, USB, display) exercises a different Redox driver.

The N100's eMMC storage uses an SDHCI controller that Redox has no driver for, so the practical boot path is a USB flash drive or an M.2 NVMe SSD in the Carrier Lite's M.2 M-Key slot. 8GB RAM is plenty for Redox — the kernel and full Orbital desktop fit in well under 1GB.

## What Changes

- Add a `lattepanda-mu` system configuration (Nix profile) targeting the Carrier Lite board's hardware mix: NVMe or USB boot, RTL8168 Ethernet, Intel HD Audio, xHCI USB, UEFI GOP framebuffer display.
- Add the Realtek RTL8168 Ethernet PCI match entries to the default Carrier Lite config (the Carrier Lite's Gigabit Ethernet is a Realtek chip).
- Document the BIOS settings required for Redox boot (disable Secure Boot, set boot order, serial console redirection if available).
- Create an SD card or USB flash image builder that produces a bootable UEFI image for the Mu.
- Produce a tested bare-metal boot runbook: flash image, connect UART, power on, verify serial output, verify display, verify networking.

## Capabilities

### New Capabilities
- `bare-metal-boot`: Hardware bringup on the LattePanda Mu Carrier Lite — UEFI boot from USB/NVMe, driver selection, BIOS configuration, serial debug, and verification procedure.
- `lattepanda-mu-profile`: Nix system configuration profile for the LattePanda Mu N100 on Carrier Lite, with correct driver set, disk sizing, and hardware options.

### Modified Capabilities
<!-- No existing specs are changing at the requirement level. -->

## Impact

- **New files**: `examples/lattepanda-mu/configuration.nix`, `examples/lattepanda-mu/flake.nix`, `docs/bare-metal-lattepanda-mu.md`
- **Build system**: No changes to the module system itself — the new profile composes existing modules.
- **Drivers**: No new drivers needed for initial boot. RTL8168, NVMe, xHCI, vesad, ihdad are all already built. The eMMC (SDHCI) gap is documented but out of scope.
- **Hardware required**: LattePanda Mu (DFR1146, N100 8GB RAM, 64GB eMMC), Carrier Lite (DFR1142), heatsink, 12V PSU or USB-C PD 15V, USB flash drive or M.2 2230 NVMe SSD, USB-UART cable for serial debug.
