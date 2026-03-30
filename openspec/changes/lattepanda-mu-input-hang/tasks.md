## 1. Diagnosis

- [x] 1.1 Read usbhidd source (`drivers/usb/xhcid/usbhidd/`) to understand HID report processing loop and how interrupt transfers are re-submitted after each report
- [x] 1.2 Read xhcid interrupt transfer handling to understand how endpoint polling is scheduled and whether re-submission is automatic or requires explicit action from sub-drivers
- [x] 1.3 Trace the first keystroke path: identify where usbhidd receives the HID report, translates it, and writes to inputd's producer handle
- [x] 1.4 Identify the stall point: determine whether usbhidd blocks on a read (waiting for next interrupt transfer), a write (to input:producer), or exits/crashes after the first report
- [x] 1.5 Check if the `unknown usage_page 0x7 usage 0x0` warning indicates usbhidd drops the key-release report and fails to re-arm for the next key-down

## 2. Fix interrupt transfer re-submission

- [x] 2.1 If xhcid requires explicit re-submission: add interrupt transfer re-submit after each HID report delivery in usbhidd's event loop
- [x] 2.2 If usbhidd's read loop exits after first report: fix the loop to continue reading from the xhcid interface
- [x] 2.3 Handle key-release reports (usage page 0x7, usage 0x0) as normal protocol events instead of logging warnings

## 3. Build and test

- [x] 3.1 Create any needed patches in `nix/pkgs/patches/` and wire into per-crate overrides in `nix/flake-modules/packages.nix`
- [x] 3.2 Build, flash via JetKVM virtual media, and boot
- [ ] 3.3 Verify multiple keystrokes flow through to the login prompt without stalling
- [ ] 3.4 Complete a full login (type "root", Enter, type "redox", Enter) and verify shell prompt appears

## Status

Transfers #1-3 succeed then xHC stops polling. The endpoint handle reopen
in usbhidd only resets scheme file handles, not xHC hardware state. The
fix requires xhcid changes: Stop Endpoint + Set TR Dequeue Pointer command
cycle between interrupt IN transfers to reset the hardware ring state on
Intel N100. This is a separate xhcid-level change.

Progress so far: USB enabled in dev profile, inputd wired for USB-only
mode, mouse interfaces filtered, resilient transfer loop with diagnostics.
The input pipeline works for ~3 reports before the hardware stalls.
