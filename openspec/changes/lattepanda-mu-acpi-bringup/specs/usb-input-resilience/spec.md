## ADDED Requirements

### Requirement: usbhidd does not block boot when input scheme unavailable
The usbhidd driver SHALL NOT block indefinitely when the `input:` scheme (provided by inputd) is not available. It SHALL timeout or fail gracefully so that other boot services can proceed.

#### Scenario: inputd not running
- **WHEN** xhcid spawns usbhidd for a USB HID keyboard and inputd has not registered the `input:` scheme
- **THEN** usbhidd exits with an error message within 5 seconds instead of blocking forever

#### Scenario: inputd starts after usbhidd
- **WHEN** usbhidd fails because inputd wasn't ready, and inputd starts later
- **THEN** a subsequent USB device hotplug (or xhcid re-enumeration) can spawn a new usbhidd that connects successfully

### Requirement: xhcid sub-driver spawn uses correct paths
The xhcid driver SHALL spawn sub-drivers (usbhidd, usbhubd) using paths that resolve correctly in both the initfs and rootfs environments.

#### Scenario: usbhidd found during initfs boot
- **WHEN** xhcid enumerates a USB HID device during initfs boot
- **THEN** xhcid spawns usbhidd from a path that exists in the initfs namespace

#### Scenario: usbhidd found after rootfs switchroot
- **WHEN** xhcid enumerates a USB HID device after rootfs switchroot
- **THEN** xhcid spawns usbhidd from a path that exists in the rootfs namespace

### Requirement: vesad provides display scheme for input chain
The vesad daemon SHALL register the `display:` scheme when UEFI GOP framebuffer information is available, enabling the inputd→usbhidd→keyboard input chain.

#### Scenario: vesad receives framebuffer env vars
- **WHEN** the bootloader sets FRAMEBUFFER_ADDR, FRAMEBUFFER_WIDTH, FRAMEBUFFER_HEIGHT, FRAMEBUFFER_STRIDE and vesad starts
- **THEN** vesad maps the GOP framebuffer and registers the `display:` scheme

#### Scenario: vesad without framebuffer info
- **WHEN** vesad starts without FRAMEBUFFER_WIDTH in its environment
- **THEN** vesad exits cleanly with "No boot framebuffer" and signals readiness (does not hang)
