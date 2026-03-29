## ADDED Requirements

### Requirement: Kernel serial output on Carrier Lite UART
The Redox kernel SHALL emit boot log messages to the Carrier Lite's SIO_UART header so that a user connected with a USB-UART cable at 115200 8N1 sees kernel output after the bootloader hands off.

#### Scenario: Kernel boot messages on serial
- **WHEN** a USB-UART cable is connected to the Carrier Lite UART header and the kernel starts
- **THEN** kernel boot messages (memory info, driver loading, init progress) appear on the serial terminal

#### Scenario: Serial continues after bootloader
- **WHEN** the bootloader completes (UEFI serial works) and the kernel takes over
- **THEN** serial output continues without interruption on the same UART

### Requirement: UART I/O port identified
The bringup process SHALL determine the actual I/O port or PCI device address of the Carrier Lite's SIO_UART by booting Linux and inspecting `dmesg` and `/proc/ioports`.

#### Scenario: Linux UART audit
- **WHEN** a Linux live USB boots on the LattePanda Mu
- **THEN** `dmesg | grep -i uart` and `cat /proc/ioports | grep -i serial` identify whether the UART is at legacy COM1 (0x3F8), an alternative I/O port, or a PCI HSUART device

### Requirement: Interactive serial login
The getty service SHALL provide a login prompt on the serial console so that a user can log in via the UART without needing HDMI or USB keyboard.

#### Scenario: Serial login prompt
- **WHEN** the system boots to the rootfs and getty starts on the debug: scheme
- **THEN** the serial terminal shows `redox login:` and accepts username/password input
