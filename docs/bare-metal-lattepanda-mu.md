# LattePanda Mu (Intel N100) — Bare Metal Bringup

Board: LattePanda Mu compute module + Carrier Lite baseboard
CPU: Intel N100 (Alder Lake-N, 4 cores)
UEFI: AMI Aptio V (version 2.22.1287)
Storage: M.2 NVMe SSD installed
Network: RTL8168 Gigabit Ethernet (onboard)

## Current Boot State

**Status: Boots to interactive login prompt with USB keyboard input**

Redox OS boots via JetKVM virtual media (UEFI live mode). The full USB
HID pipeline works: xhcid → usbhidd → inputd → fbcond → getty. Users
can log in and run commands via USB keyboard on HDMI, or via serial
console.

### What Works

- UEFI bootloader loads and starts kernel
- Kernel boots, mounts initfs, runs init scripts
- ACPI: acpid loads DSDT/SSDT (AML Match opcode implemented)
- Display: vesad maps GOP framebuffer, fbcond renders text console
- USB: xhcid enumerates JetKVM HID devices, usbhidd delivers keyboard input
- Input: inputd routes keyboard events to fbcond VT, getty receives keypresses
- Login: root login works, Ion shell functional
- Serial console: bidirectional via COM0 (BIOS label), 115200 8N1

### What Doesn't Work

- **Kernel serial output**: bootloader UEFI serial works, kernel `debug:` output
  does not reach the serial port after ExitBootServices. Userspace `eprintln!`
  also doesn't appear. See [Serial Console](#serial-console) section.
- **Networking**: rtl8168d not loaded. RTL8168 NIC is likely on a PCIe
  subordinate bus (behind a PCIe bridge). pcid only enumerates bus 0
  devices. No `net`, `ip`, or `tcp` schemes registered.
- **NVMe**: nvmed not detecting the M.2 SSD. Same PCIe bridge enumeration
  issue — NVMe controller is behind a PCIe bridge on a subordinate bus.
- **PCIe bridge enumeration**: All detected PCI devices are on bus 00.
  Devices behind PCIe bridges (NIC, NVMe) are invisible to pcid.

## Serial Console

### BIOS Configuration

Found under Advanced → Serial Port Console Redirection:

| Setting | Value |
|---------|-------|
| Port | COM0 |
| Console Redirection | Enabled |
| Terminal Type | VT100Plus |
| Baud Rate | 115200 |
| Data Bits | 8 |
| Parity | None |
| Stop Bits | 1 |
| Flow Control | None |

### Host Connection

USB-to-serial adapter connected from the host machine to the Carrier Lite
UART header. Appears as `/dev/ttyUSB0` on the host.

```
stty -F /dev/ttyUSB0 115200 raw -echo
cat /dev/ttyUSB0    # capture output
```

### What Works

- BIOS menu output appears on serial (VT100 escape codes)
- Bootloader output appears (RedoxFS detection, live copy progress, resolution selection)
- After boot: getty on `debug:` provides interactive serial console login
- Bidirectional: typing on serial terminal reaches the Ion shell

### What Doesn't Work

- Kernel boot messages do not appear between bootloader handoff and login prompt
- Userspace `eprintln!` (e.g., from xhcid) does not appear on serial
- `cat /scheme/debug` returns EBADF (error 9) — debug: scheme doesn't support
  plain file reads from userspace

### Analysis

The Redox kernel initializes serial via `serial_debug` feature (enabled by
default). It tries COM1 at I/O port 0x3F8:

```rust
// arch/x86_shared/device/serial.rs
let mut com1 = SerialPort::<Pio<u8>>::new(0x3F8);
if com1.init().is_ok() {
    *COM1.lock() = SerialKind::Ns16550Pio(com1);
}
```

The BIOS labels this port as "COM0". The UEFI bootloader uses the UEFI
Serial I/O Protocol which works. After ExitBootServices, the kernel
must talk to the hardware directly. Either:

1. `SerialPort::init()` fails (no 16550-compatible UART detected at 0x3F8)
2. The UART needs reinitialization that the UEFI runtime was handling
3. The N100 uses an Intel HSUART (PCI/MMIO-based) that the UEFI
   abstracted as COM0, but isn't a legacy 16550 at 0x3F8

**Next step**: Boot Linux live USB, run `cat /proc/ioports | grep serial`
and `dmesg | grep -i uart` to determine the actual UART hardware type
and I/O port.

## USB Input Chain

### Architecture

```
JetKVM USB HID → xhcid (xHCI host controller driver)
                   → usbhidd (HID report parser)
                     → inputd (input event multiplexer)
                       → fbcond (framebuffer console, VT)
                         → getty (login prompt)
```

### Patches Applied

1. **xhcid driver paths** (`patch-xhcid-driver-paths.py`): Try
   `/usr/lib/drivers/` then `/bin/` for sub-driver lookup (initfs compat).

2. **xhcid Stdio fix**: `Stdio::null()` → `Stdio::inherit()` to avoid
   opening `/dev/null` before `file:` scheme exists.

3. **usbhidd timeout** (`patch-usbhidd-timeout.py`): 5-second timeout
   on `/scheme/input/producer` open instead of blocking forever.

4. **usbhidd resilient loop** (`patch-usbhidd-resilient-loop.py`):
   - Wrap transfer_read in error handling with retry logic
   - Filter mouse interfaces (protocol=2) to prevent scheme loop starvation
   - Map usage 0x00 on keyboard page to no-op (empty boot protocol slots)
   - Reopen endpoint handle after each successful transfer (workaround for
     Intel N100 xHC that stops generating Transfer Events after ~3 transfers)

5. **inputd daemon order** (`patch-inputd-daemon-order.py`): Move
   setup_logging inside daemon callback.

6. **xhcid interrupt diagnostics** (`patch-xhcid-interrupt-restart.py`):
   eprintln! logging for interrupt endpoint transfers (pre/post with
   completion codes).

### Failed Approach: Stop Endpoint + Set TR Dequeue Pointer

Attempted to issue xHCI Stop Endpoint Command + Set TR Dequeue Pointer
Command between interrupt transfers to reset the hardware ring state.
This **deadlocked xhcid**: the `execute_command` await for Stop Endpoint
never returned, blocking the single-threaded scheme loop. All USB
operations froze (`ls /scheme/input` hung indefinitely).

Root cause: xhcid processes scheme requests and xHCI commands on the
same thread. The Stop Endpoint command goes through `execute_command`
which waits for a Command Completion Event from the IRQ reactor. If the
IRQ reactor or event ring processing is blocked/delayed, the command
never completes, and the scheme loop is stuck.

Additionally, the existing `restart_endpoint()` → `set_tr_deque_ptr()`
has a bug: it uses `StreamContextType::PrimaryRing` (SCT=1) and
`stream_id=1`, but the xHCI spec (section 4.6.10) requires SCT=0 and
stream_id=0 for non-stream endpoints like interrupt endpoints.

### Working Approach: Endpoint Handle Reopen

The usbhidd resilient loop patch reopens the endpoint handle after each
successful transfer. This resets the xhcid scheme-level state machine
(EndpIfState back to Init). Combined with the transfer retry logic, this
keeps keyboard input flowing on the Intel N100 hardware.

## ACPI / AML Match Opcode

**Status**: Implemented and working on hardware

The Intel N100 DSDT uses the AML Match opcode (0x89). Implementation
uses multi-phase retirement in the AML interpreter. See commit history
for details. acpid successfully loads DSDT/SSDT on N100 hardware
(`kernel.acpi` scheme is registered).

## PCI Devices (Bus 0 Only)

pcid detects devices on bus 00 only. Devices behind PCIe bridges
are not enumerated. Detected addresses include:

- `0000:00:00.0` — Host bridge
- `0000:00:02.0` — Integrated graphics (Intel UHD)
- `0000:00:14.0` — xHCI USB controller (working)
- `0000:00:14.2` — Shared SRAM / PMC
- `0000:00:15.x` — Serial IO (I2C, UART, SPI)
- `0000:00:16.0` — MEI (Management Engine Interface)
- `0000:00:17.x` — AHCI / SATA
- Various `0000:00:1x.x` — PCH devices

**Missing** (behind PCIe bridges, not enumerated):
- RTL8168 Gigabit Ethernet
- NVMe controller

**Next step**: Add PCIe bridge enumeration to pcid, or boot Linux to
get `lspci -nn` output showing the full PCI topology.

## BIOS Settings

### USB Configuration (Chipset → PCH-IO)

| Setting | Value |
|---------|-------|
| USB2.0 Controller | Enabled |
| USB3.0 Controller | Enabled |
| xDCI Support | Disabled |
| Enable HSII on xHCI | Enabled |

### Boot

Boots from "UEFI: JetKVM Virtual Media, Partition 1" via virtual USB
flash drive. Live mode copies the entire 820 MiB RedoxFS to RAM.

## Configuration

See `examples/lattepanda-mu/configuration.nix`.

Key settings:
- `initfsExcludeDaemons = ["ps2d" "usbscsid"]` — no PS/2 on N100
- `initfsEnableGraphics = true` — vesad + fbcond for HDMI text console
- `inputdVT = 2` — match fbcondVT so keyboard input reaches text console
- `usbEnable = true` — xhcid + usbhidd + inputd
- `audioEnable = false` — not tested yet

## Open Issues

1. **PCIe bridge enumeration** — pcid needs to scan subordinate buses
   to find NVMe and RTL8168. This blocks networking and NVMe storage.

2. **Kernel serial output** — need to determine why kernel debug output
   doesn't reach serial after ExitBootServices. Likely UART hardware
   type mismatch (HSUART vs legacy 16550).

3. **`lived` panic** — `lived` crashes with `NotPresent` unwrap at
   `src/lib.rs:13:40`. May be related to missing PCI devices.

4. **xHCI interrupt transfer stall** — Intel N100 xHC stops generating
   Transfer Events after ~3 interrupt transfers. Current workaround
   (endpoint handle reopen) works. Proper fix (Stop Endpoint + Set TR
   Dequeue Pointer) deadlocks due to xhcid's single-threaded design.
   Fixing this properly requires either making xhcid's command path
   async-safe or using a separate thread for xHCI commands.
