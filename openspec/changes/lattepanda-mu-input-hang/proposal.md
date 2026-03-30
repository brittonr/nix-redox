## Why

Redox OS boots to a login prompt on HDMI on the LattePanda Mu (Intel N100) with keyboard input from JetKVM USB HID partially working — the first keystroke registers and echoes on screen, then input stalls. The full display chain (vesad → fbcond → getty → login) and input chain (xhcid → usbhidd → inputd → fbcond → PTY → getty) are functional, but something in the event pipeline stops forwarding after the first key event. Without fixing this, the system is unusable despite being fully booted.

## What Changes

- Diagnose where the input pipeline stalls after the first keystroke: usbhidd HID report processing, inputd event dispatch, fbcond event queue re-arming, or getty PTY bridge event loop.
- Fix the stall so continuous keyboard input flows through to the login prompt.
- Verify login completes (type username, password, get shell).

## Capabilities

### New Capabilities
- `usb-hid-continuous-input`: Continuous keyboard input from USB HID devices through the full event pipeline (usbhidd → inputd → fbcond → getty) without stalling after the first keystroke.

### Modified Capabilities

## Impact

- `drivers/usb/xhcid/` and `drivers/inputd/` — usbhidd HID report handling, inputd event dispatch
- `drivers/graphics/fbcond/` — fbcond VT event consumption and re-arming
- `nix/pkgs/patches/` — possible new patches for event handling fixes
- `nix/flake-modules/packages.nix` — per-crate overrides if source patches needed
