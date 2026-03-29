## Context

Redox OS boots on the LattePanda Mu (Intel N100, Carrier Lite board) to a login prompt via UEFI live mode, but all PCI peripherals are non-functional. The boot path today excludes acpid entirely because the AML interpreter panics on the `Match` opcode (used in N100 DSDT tables). Without ACPI:

- pcid falls back to PCI 3.0 config space (I/O ports 0xCF8/0xCFC), which reads BAR addresses as all zeros on this hardware
- xhcid can enumerate USB devices but transactions fail (completion code 0x4 = USB Transaction Error) because MMIO registers aren't mapped
- vesad can't physmap the GOP framebuffer
- NVMe, Ethernet, and Audio drivers all fail at BAR mapping

The current working state uses the kernel's early framebuffer console (pre-vesad) and getty on the `debug:` scheme for the login prompt. No keyboard input, no network, no persistent storage.

The bootloader serial (UEFI protocol) works on the Carrier Lite UART header, but the kernel's direct I/O to COM1 (0x3F8) produces no output — the N100's UART is likely routed through a PCI-based HSUART rather than legacy ISA.

## Goals / Non-Goals

**Goals:**
- Implement the AML `Match` opcode so acpid fully initializes on N100 ACPI tables
- Get pcid working with MCFG-based PCIe config access (proper BAR mapping)
- Boot to an interactive shell with USB keyboard input via xhcid→usbhidd→inputd→fbcond
- Establish serial console for debug (either fix kernel COM1 output or add HSUART support)
- Get at least one peripheral working: Ethernet (rtl8168d) or NVMe (nvmed)

**Non-Goals:**
- Full ACPI power management, suspend/resume, thermal management
- WiFi, Bluetooth, or eMMC (SDHCI) support
- Intel GPU native driver (vesad GOP framebuffer is sufficient)
- Orbital graphical desktop (blocked on separate orbital build issue)
- Automated CI on this hardware

## Decisions

### 1. Implement Match opcode properly (not stub)

**Rationale**: The stub approach (returning error + making load_table resilient) lets acpid start but produces incomplete ACPI namespace. With MCFG tables available, pcid gets real BAR addresses, but the incomplete namespace may cause driver hangs during IRQ routing or device configuration. A proper Match implementation gives the AML interpreter complete table processing.

**Approach**: The Match opcode format is `SearchPkg MatchOp1 Operand1 MatchOp2 Operand2 StartIndex` where MatchOp1/MatchOp2 are raw bytes interleaved with TermArgs. The existing `OpInFlight` parser model doesn't support interleaved bytes. Use a multi-phase approach:
1. Read SearchPkg as TermArg (first in-flight op)
2. In the retirement handler, read MatchOp1 byte from the stream, start a new in-flight for Operand1
3. Repeat for MatchOp2 + Operand2 + StartIndex
4. Final retirement performs the actual search and returns the index or ONES

**Alternative considered**: Stub with `Err(IllegalOpcode)` + resilient `load_table` — tested, acpid starts but drivers hang after switchroot. The incomplete AML evaluation likely leaves device configuration in a bad state.

### 2. Debug post-switchroot hang before optimizing

**Rationale**: When acpid runs with the stub (resilient load_table), the system hangs after switchroot. Before implementing Match properly, we need to understand WHY the hang occurs. It could be: (a) a driver blocking on an acpid query that returns incomplete data, (b) IRQ routing misconfigured, (c) a specific PCI device driver hanging during init. Adding kernel syscall debug tracing for the hang will identify the root cause before investing in a full Match implementation.

### 3. Serial: boot Linux first to identify UART routing

**Rationale**: The Carrier Lite UART header works with UEFI serial but not kernel direct I/O. Before writing HSUART support, boot a Linux live USB on the board and check `dmesg | grep -i uart` and `cat /proc/ioports | grep serial` to determine if the UART is at a non-standard I/O port, a PCI HSUART, or needs specific SIO chip configuration. This is a 10-minute investigation that avoids guesswork.

### 4. usbhidd: timeout instead of blocking

**Rationale**: When usbhidd is spawned by xhcid and tries to open `/scheme/input/producer` (provided by inputd), it blocks forever if inputd hasn't started. This stalls the boot. Fix: add a timeout or non-blocking open with retry+fallback. If the input scheme isn't available after N seconds, usbhidd should exit with an error (like it did before the path fix) rather than block.

## Risks / Trade-offs

- **[Match implementation complexity]** → The interleaved byte/TermArg parsing requires modifying the AML interpreter's core parser model. Risk of introducing bugs in other opcode parsing. Mitigation: extensive testing in QEMU before bare metal, add Match-specific unit tests.
- **[Hang root cause unknown]** → The post-switchroot hang with acpid could be caused by multiple factors. Mitigation: use kernel syscall debug tracing to identify the blocking process and syscall.
- **[UART might need kernel driver]** → If the UART is a PCI HSUART (Intel LPSS), kernel serial support would need a new driver. Mitigation: check Linux first — if it's just a different I/O port, a kernel config change suffices.
- **[ACPI table variations]** → Other real hardware may have different unimplemented opcodes. Mitigation: make the AML interpreter more resilient generally (log and continue pattern for non-critical ops).
