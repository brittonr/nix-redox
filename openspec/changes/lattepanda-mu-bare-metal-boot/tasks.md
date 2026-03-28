## 1. PCI Device Audit (Linux pre-boot)

- [ ] 1.1 Boot Linux (USB live image) on the LattePanda Mu + Carrier Lite and capture `lspci -nn` output
- [ ] 1.2 Confirm Ethernet NIC PCI ID is 10EC:8168 (RTL8111, per official Carrier Lite docs)
- [ ] 1.3 Identify the Intel HD Audio device ID (check if it matches ICH6 0x2668 or ICH9 0x293e or a newer Alder Lake ID)
- [ ] 1.4 Identify the xHCI USB controller device ID
- [ ] 1.5 Identify the NVMe controller device ID (if M.2 SSD installed)
- [ ] 1.6 Check if SDHCI (eMMC) controller appears in PCI list and note its ID for future driver work
- [ ] 1.7 Check UART routing — run `dmesg | grep -i uart` to see if it's legacy ISA COM1 or PCI HSUART
- [ ] 1.8 Document all PCI IDs in `docs/bare-metal-lattepanda-mu.md` with driver mapping notes

## 2. BIOS Configuration

- [ ] 2.1 Enter BIOS (Del key at boot), document the default settings
- [ ] 2.2 Disable Secure Boot (if enabled by default)
- [ ] 2.3 Set boot order: USB first, then NVMe, then eMMC
- [ ] 2.4 Check for serial console redirection settings (Advanced → Serial Port Configuration or similar)
- [ ] 2.5 Note TDP setting (default should be fine, but record it)
- [ ] 2.6 Document all BIOS changes in the runbook

## 3. Nix Configuration Profile

- [ ] 3.1 Create `examples/lattepanda-mu/configuration.nix` with hardware driver selection: nvmed, ahcid, rtl8168d, e1000d, xhcid, vesad, ihdad
- [ ] 3.2 Create `examples/lattepanda-mu/flake.nix` that imports the configuration
- [ ] 3.3 Set hostname to `lattepanda-mu`, enable graphics, enable networking (DHCP), enable audio, enable USB
- [ ] 3.4 Include user accounts (root + user) matching the graphical-desktop example pattern
- [ ] 3.5 Set disk image size to 1024MB, initfs to 128MB, VM memory to 4096MB
- [ ] 3.6 Add any missing PCI device IDs to `extraPciDrivers` in the configuration (based on audit from step 1)
- [ ] 3.7 `git add` the new files and verify `nix build` produces a disk image

## 4. Update pcid Registry (if needed)

- [ ] 4.1 Compare PCI IDs from step 1 against `nix/redox-system/modules/build/pcid.nix` registry
- [ ] 4.2 Add any missing Alder Lake-N device IDs for HD Audio, Ethernet, or USB controllers
- [ ] 4.3 Rebuild and verify pcid TOML includes the new entries

## 5. Flash and First Boot (USB)

- [ ] 5.1 Write the disk image to a USB flash drive with `dd if=result/redox.img of=/dev/sdX bs=4M status=progress`
- [ ] 5.2 Connect USB-UART cable to Carrier Lite UART header, open terminal at 115200 8N1
- [ ] 5.3 Connect HDMI monitor and USB keyboard
- [ ] 5.4 Plug USB drive into Carrier Lite USB 3.2 port, power on
- [ ] 5.5 Verify bootloader messages appear on serial or HDMI
- [ ] 5.6 Verify kernel boots and pcid-spawner loads drivers
- [ ] 5.7 Verify shell prompt or Orbital login screen appears
- [ ] 5.8 Document any boot failures, kernel panics, or missing drivers

## 6. Hardware Verification

- [ ] 6.1 Verify Ethernet: plug in cable, check DHCP lease, test DNS resolution
- [ ] 6.2 Verify USB: test keyboard input in shell or Orbital
- [ ] 6.3 Verify display: confirm Orbital renders on HDMI (if graphical config)
- [ ] 6.4 Verify audio: check that ihdad loads (audio output test if speakers/headphones available)
- [ ] 6.5 Verify NVMe: if M.2 SSD installed, check that nvmed detects it and disk: scheme is available

## 7. NVMe Persistent Install (optional)

- [ ] 7.1 Write disk image to M.2 2230 NVMe SSD (from Linux or another machine)
- [ ] 7.2 Install SSD in Carrier Lite M-Key slot
- [ ] 7.3 Set BIOS to boot from NVMe
- [ ] 7.4 Boot and verify full system from NVMe

## 8. Runbook Documentation

- [ ] 8.1 Write `docs/bare-metal-lattepanda-mu.md` with: hardware BOM, BIOS setup, image build, flashing, boot verification, PCI device table, known issues
- [ ] 8.2 Add troubleshooting section for common failures (no serial output, no display, no network)
- [ ] 8.3 Note the eMMC/WiFi gaps and link to future work
