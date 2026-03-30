## ADDED Requirements

### Requirement: USB HID interrupt transfers re-submit after each report
The xhcid/usbhidd driver pair SHALL re-submit interrupt transfer requests after processing each HID report so the host controller continues polling the device endpoint.

#### Scenario: Multiple keystrokes in sequence
- **WHEN** a USB HID keyboard sends a key-down report followed by a key-up report followed by another key-down report
- **THEN** all three reports SHALL be received and processed by usbhidd without stalling

#### Scenario: JetKVM hidg0 write does not block
- **WHEN** a JetKVM USB HID gadget writes a second HID report to /dev/hidg0 after the first report was consumed
- **THEN** the write SHALL complete without blocking (the host controller polls the endpoint)

### Requirement: Continuous keyboard input reaches the login prompt
The full input pipeline (usbhidd → inputd → fbcond → PTY → getty) SHALL forward all keyboard events without dropping or stalling after the first event.

#### Scenario: Type username at login prompt
- **WHEN** a user types "root" followed by Enter at the "redox login:" prompt via USB HID keyboard
- **THEN** all five characters SHALL echo on screen and login SHALL proceed to the password prompt

#### Scenario: Complete login flow
- **WHEN** a user types username, presses Enter, types password, and presses Enter
- **THEN** the system SHALL authenticate and present a shell prompt

### Requirement: Key-release reports handled without warnings
usbhidd SHALL handle usage page 0x7 (Keyboard/Keypad) key-release reports (usage 0x0) without logging warnings, since key-release is a normal part of the HID keyboard protocol.

#### Scenario: Key-release after key-down
- **WHEN** a USB HID keyboard sends a key-down report for 'a' followed by a key-release report (usage 0x0)
- **THEN** usbhidd SHALL process both reports without logging "unknown usage_page" warnings
