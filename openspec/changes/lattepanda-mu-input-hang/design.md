## Context

The LattePanda Mu bare metal boot reaches a login prompt on HDMI with working display output. The input pipeline is: JetKVM USB HID gadget → xhcid (USB host controller driver) → usbhidd (HID report parser) → inputd (input: scheme, event routing) → fbcond (text console, VT event handling) → PTY → getty → login.

The first keystroke flows through the entire pipeline and echoes on screen. Subsequent keystrokes do not appear. The `@usbhidd:133 WARN unknown usage_page 0x7 usage 0x0` message appears once — usage page 0x7 is the Keyboard/Keypad page, usage 0x0 is the key-release event. This suggests usbhidd receives the release report but may not handle the state transition correctly for subsequent key-down reports.

The JetKVM `/dev/hidg0` write blocks after the first key, indicating the target USB host isn't polling the HID endpoint for subsequent reports. This points to xhcid or usbhidd blocking rather than a downstream (inputd/fbcond/getty) issue.

## Goals / Non-Goals

**Goals:**
- Identify the exact component where the input pipeline stalls after the first key event.
- Fix the stall so keyboard input flows continuously.
- Verify end-to-end login (username + password + shell prompt).

**Non-Goals:**
- Mouse input support (separate effort).
- USB hotplug / reconnect handling.
- Performance optimization of the HID event path.
- Non-JetKVM USB keyboard testing (same code path, but not validated here).

## Decisions

**Diagnosis approach: serial/kernel debug tracing rather than code-reading**

The stall could be in any of 5 components. Rather than reading all the source code, use `kernelSyscallDebug` with process filtering for `usbhidd` and `inputd` to trace syscalls around the hang. If the process is blocked in a `read` or `write` syscall, the trace will show exactly where. If the process is busy-looping, the trace will show repeated syscalls.

Alternative considered: adding eprintln!() debug prints to each component. Slower iteration (rebuild + flash + reboot for each change) and less information than syscall tracing.

**Likely root cause: usbhidd interrupt transfer re-submission**

USB HID uses interrupt transfers. xhcid submits an interrupt transfer request, the device responds with a HID report, xhcid delivers it to usbhidd. For continuous input, usbhidd must re-submit the interrupt transfer after processing each report. If re-submission doesn't happen, no more reports arrive and `/dev/hidg0` writes block (the host never polls).

Alternative hypothesis: inputd's event dispatch could be the issue. But the `/dev/hidg0` write blocking points to the USB layer, not the scheme layer. The host USB controller has stopped polling the device endpoint.

**Fix strategy: patch usbhidd or xhcid interrupt transfer handling**

If the interrupt transfer re-submission is missing, add it. This would be a new patch in `nix/pkgs/patches/` applied via per-crate override in `nix/flake-modules/packages.nix`, matching the pattern used for other driver patches.

## Risks / Trade-offs

[Risk] Diagnosis may require kernel syscall debug build which adds boot time and serial noise. → Use process-filtered debug (`mkKernelSyscallDebug { debugProcesses = ["usbhidd"]; }`) to limit output.

[Risk] The stall could be a race condition that doesn't reproduce consistently. → The current reproduction is 100% — every boot, first key works, second doesn't. Deterministic bugs are easier.

[Risk] Fix may require changes to xhcid (complex driver) rather than usbhidd (simpler). → Start with usbhidd since the `unknown usage_page` warning suggests it's the last component to process data. If xhcid is the issue, the interrupt transfer scheduling code is well-isolated.
