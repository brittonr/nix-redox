## ADDED Requirements

### Requirement: Nix configuration profile exists
A Nix configuration profile SHALL exist at `examples/lattepanda-mu/configuration.nix` that builds a bootable Redox disk image for the LattePanda Mu (DFR1146) on the Carrier Lite board.

#### Scenario: Profile builds a disk image
- **WHEN** a user runs `nix build` with the lattepanda-mu configuration
- **THEN** the build produces a raw disk image with a UEFI ESP and a RedoxFS root partition

### Requirement: Correct storage drivers selected
The profile SHALL include nvmed for M.2 NVMe and ahcid as fallback. It SHALL NOT depend on eMMC (SDHCI) support.

#### Scenario: NVMe driver in initfs
- **WHEN** the disk image boots on the LattePanda Mu with an M.2 NVMe SSD installed
- **THEN** pcid-spawner loads nvmed, which detects the NVMe controller and provides the disk: scheme

### Requirement: Correct network driver selected
The profile SHALL include rtl8168d for the Carrier Lite's RTL8111 Gigabit Ethernet (confirmed by official docs, PCI ID 10EC:8168).

#### Scenario: Ethernet driver loaded
- **WHEN** the system boots and pcid-spawner enumerates PCI devices
- **THEN** the Realtek NIC is matched and rtl8168d (or e1000d) starts, providing the network: scheme

### Requirement: USB support enabled
The profile SHALL enable USB support (xhcid, usbhidd) so USB keyboards, mice, and storage devices work.

#### Scenario: USB HID devices functional
- **WHEN** a USB keyboard is connected to the Carrier Lite
- **THEN** xhcid detects the USB host controller, usbhidd provides HID input to the system

### Requirement: Display support via vesad
The profile SHALL enable graphics with vesad for the UEFI GOP framebuffer. The HDMI 2.0 output on the Carrier Lite SHALL display Orbital or fbcond.

#### Scenario: Graphical boot with Orbital
- **WHEN** graphics are enabled in the profile and an HDMI monitor is connected
- **THEN** vesad provides the display: scheme using the GOP framebuffer and Orbital renders the desktop

### Requirement: Audio support via ihdad
The profile SHALL include ihdad for Intel HD Audio, which is the audio controller on the N100 SoC.

#### Scenario: Audio driver loaded
- **WHEN** the system boots and pcid-spawner enumerates the HDA controller
- **THEN** ihdad starts and provides the audio: scheme

### Requirement: Disk image sized for 8GB RAM system
The profile SHALL set a disk image size appropriate for the target (no larger than necessary). The virtualisation memory setting SHALL reflect the 8GB physical RAM if the image is also tested in a VM.

#### Scenario: Image fits on USB flash drive
- **WHEN** the disk image is built
- **THEN** the image is no larger than 1024MB (fits on any common USB drive) and the VM memory is set to 4096MB or less

### Requirement: Hostname identifies the board
The profile SHALL set the hostname to `lattepanda-mu` so the system is identifiable on the network and in shell prompts.

#### Scenario: Hostname set
- **WHEN** the system boots
- **THEN** the hostname is `lattepanda-mu`
