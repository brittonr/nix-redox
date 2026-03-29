# LattePanda Mu (Intel N100) — Bare Metal Bringup

Status: **Work in progress**

Board: LattePanda Mu compute module + Carrier Lite baseboard
CPU: Intel N100 (Alder Lake-N, 4 cores)
UEFI: AMI Aptio V

## Current Boot State

Redox OS boots to a login prompt via UEFI live mode on USB flash drive.
The login prompt appears on HDMI via the kernel's early framebuffer
console (pre-vesad) with getty on the `debug:` scheme. No keyboard
input, no network, no persistent storage.

### What Works

- UEFI bootloader loads and starts kernel
- Kernel boots, mounts initfs, runs init scripts
- Getty provides login prompt on `debug:` (serial output visible via bootloader UEFI serial)
- JetKVM provides remote HDMI capture and virtual media boot

### What Doesn't Work (Yet)

- **ACPI**: acpid panicked on AML `Match` opcode in N100 DSDT tables. Now implemented (see below), needs testing.
- **PCI**: Without ACPI/MCFG, pcid falls back to PCI 3.0 config space (0xCF8/0xCFC). BAR addresses read as zeros on this hardware.
- **USB**: xhcid enumerates devices but USB transactions fail (completion code 0x4 = USB Transaction Error) due to unmapped MMIO.
- **Display**: vesad can't physmap the GOP framebuffer without ACPI memory region tables.
- **Ethernet**: rtl8168d can't read valid BAR addresses.
- **NVMe**: nvmed can't read valid BAR addresses.
- **Serial**: Kernel serial output doesn't reach the Carrier Lite UART header. Bootloader UEFI serial works. Likely PCI HSUART vs legacy COM1 routing issue.

## UART Investigation

**Status**: Pending Linux audit

The Carrier Lite has a UART header connected to the SIO_UART pins on the
Mu module. UEFI serial protocol works (bootloader output visible), but
the kernel's direct I/O to COM1 (0x3F8) produces no output.

**Next step**: Boot a Linux live USB and run:
```
dmesg | grep -i uart
cat /proc/ioports | grep -i serial
lspci -nn
```
to determine whether the UART is at a non-standard I/O port, routed
through a PCI HSUART device, or requires SIO chip configuration.

## AML Match Opcode

**Status**: Implemented, needs hardware testing

The Intel N100's DSDT tables use the AML `Match` opcode (0x89) for
searching packages. The Redox acpi crate's AML interpreter did not
implement this opcode (returned `todo!()`), causing a panic during
DSDT loading.

### Implementation

The Match opcode has an unusual encoding that interleaves raw bytes
between TermArgs:

```
DefMatch := 0x89 SearchPkg MatchOp1(byte) Operand1 MatchOp2(byte) Operand2 StartIndex
```

The interpreter's `OpInFlight` model normally expects either all TermArgs
or pre-loaded bytes followed by TermArgs (like `Fatal` or `OpRegion`).
Match needs bytes BETWEEN dynamically-evaluated TermArgs.

Solution: multi-phase retirement using the same `Opcode::Match`:
1. Phase 1: collect SearchPkg (1 TermArg), then read MatchOp1 byte
2. Phase 2: collect Operand1 (1 TermArg), then read MatchOp2 byte
3. Phase 3: collect Operand2 + StartIndex (2 TermArgs), execute search

Each phase retirement reads the next raw byte from the stream and starts
a new `OpInFlight` with the accumulated arguments. The final phase
performs the package search using the six match operators:
- MTR (0): always true
- MEQ (1): element == operand
- MLE (2): element <= operand
- MLT (3): element < operand
- MGE (4): element >= operand
- MGT (5): element > operand

Returns the index of the first matching element, or ONES (0xFFFFFFFFFFFFFFFF)
if no match is found.

## USB Input Chain

**Status**: Timeout fix implemented, needs testing

### usbhidd Timeout

The usbhidd driver blocked forever when trying to open
`/scheme/input/producer` if inputd hadn't registered the `input:`
scheme yet. Fixed by adding a 5-second timeout using a thread +
mpsc channel pattern. On timeout, usbhidd exits with an error
instead of hanging the boot sequence.

### xhcid Sub-driver Path Lookup

The xhcid driver spawns sub-drivers (usbhidd, usbhubd) and prepends
`/usr/lib/drivers/` to bare command names. This path doesn't exist in
the initfs environment where drivers are at `/bin/`. Fixed to try
`/usr/lib/drivers/<name>` first, falling back to `/bin/<name>`.

Also fixed `Stdio::null()` → `Stdio::inherit()` for stdin, since
`/dev/null` requires the `file:` scheme which isn't available during
initfs boot.

## PCI Device IDs

**Status**: Pending Linux audit (`lspci -nn`)

Expected devices on Intel N100 Carrier Lite:
- xHCI USB 3.0 controller
- RTL8168 Gigabit Ethernet
- Intel HDA audio controller
- NVMe controller (M.2 slot)
- Intel HSUART (if UART is PCI-routed)
- SDHCI (SD card controller)

## Configuration

Current config: `examples/lattepanda-mu/configuration.nix`

acpid is excluded from initfs (`initfsExcludeDaemons`) pending hardware
verification of the Match opcode implementation. Once verified, remove
`"acpid"` from the exclude list to enable full ACPI support.

## Known Issues

1. ps2d crashes on N100 (no PS/2 controller) — excluded from initfs
2. Post-switchroot hang observed with stub Match implementation — root cause unknown, may be fixed by proper Match implementation
3. vesad physmap failure without ACPI memory maps — needs ACPI working first
