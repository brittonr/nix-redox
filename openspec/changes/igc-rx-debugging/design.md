## Context

The igcd driver completes initialization, registers a network scheme at `/scheme/network.pci-0000-03-00.0_igc`, and smolnetd discovers it. Ping sends 4 ICMP packets with 0 replies. The failure point is unknown — could be any of: link not actually up, TX frames not reaching the wire, RX descriptors not receiving frames, interrupts not firing, or MAC filter rejecting packets.

Redox driver logging uses the `common::setup_logging` infrastructure which routes `log::info!`/`debug!`/`trace!` to:
1. stderr → logd → `/scheme/log` (viewable from shell, default level: Info)
2. File output → `/scheme/logging/net/pci/<name>.log` (default level: Info)
3. Log level override: bootloader env `DRIVER_PCI_LOG_LEVEL=Debug` (read from `/scheme/sys/env`)

The existing igcd has `log::info!` for MAC address and link status, but no debug/trace output for IRQ handling, descriptor state, or packet counters.

## Goals / Non-Goals

**Goals:**
- Identify the exact failure point in the igcd RX/TX path
- Add diagnostic logging that persists for future debugging
- Fix the root cause so ping and TCP work on I226-V hardware
- Keep diagnostic output off by default (Info level) to avoid performance impact

**Non-Goals:**
- Performance optimization (just needs to work)
- Multi-queue support
- MSI-X interrupt migration
- Supporting I225/I226 variants we can't test

## Decisions

**1. Add structured debug logging at key points**

Add `log::debug!()` calls at:
- `init()`: STATUS register value after reset, after link setup
- `irq()`: ICR value on each interrupt, which cause bits are set
- `init_rx()`/`init_tx()`: ring physical addresses, descriptor count, SRRCTL value
- `read_packet()`: DD bit state, packet length, RX head/tail positions
- `write_packet()`: TX descriptor state, TDT value written
- `available_for_read()`: current descriptor DD state

Use `log::trace!()` for per-packet data (hex dump of first 64 bytes).

**2. Add a periodic status log**

Every 1000th call to `irq()` or `tick()`, log: STATUS register (link state), RDH/RDT values, TDH/TDT values, ICR. This provides a heartbeat showing the driver is alive and what the hardware state is.

**3. Investigate known I225/I226 differences from E1000**

Key areas where I225/I226 diverges from classic E1000 (and where the current igcd may have bugs):

- **Interrupt registers**: I225/I226 ICR is at 0x01500, IMS at 0x01508. Classic E1000 uses 0xC0/0xD0. Verify the igcd uses the correct offsets (it does — regs.rs has them right).
- **RX descriptor writeback alignment**: The advanced RX descriptor writeback has `status_error` as a u32 at offset 8, `length` as u16 at offset 12. Verify the `AdvRxDescWb` struct layout matches hardware.
- **RXDCTL/TXDCTL ENABLE bit**: Must poll for enable to take effect. Current code polls but may not wait long enough.
- **RCTL configuration**: Current driver sets `RCTL_EN | RCTL_BAM | RCTL_SECRC | RCTL_BSIZE_2048`. May need `RCTL_UPE` (unicast promiscuous) for testing, or ensure RAL0/RAH0 MAC filter is programmed correctly.
- **Descriptor ring alignment**: I225/I226 may require 128-byte alignment for descriptor rings. DMA allocation should provide this but worth verifying.
- **CTRL.SLU timing**: Set Link Up after RCTL/TCTL enable, not before. Current order may cause issues.

**4. Use bootloader env for log level control**

Set `DRIVER_PCI_LOG_LEVEL=Debug` in the GMKtec profile's bootloader environment to enable debug output without code changes. This is read by `common::setup_logging` via `/scheme/sys/env`.

**5. Add .control interface for on-demand register dumps**

Extend the igcd scheme to accept writes to a "diag" path. When opened and written, dump all relevant registers to the log. This allows debugging from the shell without rebuilding.

## Risks / Trade-offs

- **Debug logging at trace level can affect timing**: Packet processing is latency-sensitive. Only enable trace for short debugging sessions.
- **Register reads have side effects**: Reading ICR clears interrupt causes. The diagnostic log must read ICR in the same path as the IRQ handler (already does this).
- **Descriptor struct layout bugs are subtle**: A single field offset error means the driver reads garbage for packet length or status. The FreeBSD igc_defines.h is the authoritative reference — cross-check every field.
- **Hardware errata**: Intel I225/I226 has known errata (e.g., I225 revision issues with 2.5G link). The GMKtec I226-V may be affected. Check if BIOS/firmware updates exist.
