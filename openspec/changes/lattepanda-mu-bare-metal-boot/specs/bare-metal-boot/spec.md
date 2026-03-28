## ADDED Requirements

### Requirement: UEFI boot from USB flash drive
The system SHALL produce a disk image that boots via UEFI on the LattePanda Mu when flashed to a USB drive. The bootloader SHALL load the kernel and initfs from the EFI System Partition and transition to the Redox kernel.

#### Scenario: USB boot to shell prompt
- **WHEN** the Redox disk image is written to a USB flash drive with `dd`, the drive is plugged into a Carrier Lite USB 3.2 port, and the board is powered on with USB as the first boot device in BIOS
- **THEN** the Redox bootloader loads, the kernel initializes, and the system reaches either a serial console prompt or the Orbital login screen within 60 seconds

### Requirement: UEFI boot from M.2 NVMe SSD
The system SHALL boot from an M.2 2230 NVMe SSD installed in the Carrier Lite's M-Key slot. The nvmed driver SHALL detect and mount the NVMe device during initfs.

#### Scenario: NVMe boot to shell prompt
- **WHEN** the Redox disk image is written to an M.2 2230 NVMe SSD, the SSD is installed in the Carrier Lite M-Key slot, and the board is powered on with the NVMe as the boot device
- **THEN** the Redox bootloader loads from the NVMe ESP, the kernel initializes, nvmed detects the NVMe controller, and the system reaches a shell prompt or login screen within 60 seconds

### Requirement: Serial console debug output
The kernel SHALL emit boot log messages to the serial port. A user connected to the Carrier Lite's UART header with a USB-to-UART cable SHALL see kernel boot messages.

#### Scenario: Serial output visible during boot
- **WHEN** a USB-to-UART cable is connected to the Carrier Lite Gravity-4P UART header at 115200 8N1, and the board is powered on
- **THEN** boot messages from the Redox bootloader and kernel appear on the serial terminal

#### Scenario: Serial output when UART is PCI HSUART
- **WHEN** the Carrier Lite routes the UART header to a PCI-based HSUART rather than legacy ISA COM1
- **THEN** the runbook documents the BIOS setting to enable legacy COM1 redirection, or documents that HDMI is the primary debug channel

### Requirement: BIOS configuration documented
The runbook SHALL document all BIOS settings required for Redox boot, including disabling Secure Boot, setting boot device order, and any serial port configuration.

#### Scenario: User follows runbook to configure BIOS
- **WHEN** a user follows the documented BIOS configuration steps on a factory-default LattePanda Mu
- **THEN** the board boots Redox from the USB or NVMe device on the next power cycle

### Requirement: Display output via HDMI
The system SHALL display either the Orbital GUI or a framebuffer console on a monitor connected to the Carrier Lite's HDMI 2.0 port, using the UEFI GOP framebuffer (vesad).

#### Scenario: HDMI display shows Orbital login
- **WHEN** an HDMI monitor is connected to the Carrier Lite and graphics are enabled in the configuration
- **THEN** the Orbital login screen appears on the HDMI display after boot completes

### Requirement: Ethernet networking functional
The system SHALL obtain a network connection via the Carrier Lite's RTL8111 Gigabit Ethernet using the rtl8168d driver.

#### Scenario: DHCP lease acquired
- **WHEN** the Carrier Lite Ethernet port is connected to a network with a DHCP server and the system has booted
- **THEN** the smolnetd network stack acquires an IP address via dhcpd, and `host redox-os.org` resolves successfully

### Requirement: USB input devices functional
The system SHALL accept keyboard and mouse input from USB HID devices connected to the Carrier Lite's USB ports via the xhcid and usbhidd drivers.

#### Scenario: USB keyboard input
- **WHEN** a USB keyboard is plugged into a Carrier Lite USB port and the system has booted to Orbital or a console
- **THEN** keystrokes from the USB keyboard are received by the running shell or application

### Requirement: PCI device enumeration documented
The bringup process SHALL capture the full PCI device list from the LattePanda Mu + Carrier Lite and document any devices whose IDs are not in the current pcid registry.

#### Scenario: PCI ID audit
- **WHEN** the board is booted (via Linux or Redox) and PCI devices are enumerated
- **THEN** a table of PCI vendor:device IDs is recorded in the runbook, with notes on which Redox drivers match and which IDs are missing from the pcid registry
