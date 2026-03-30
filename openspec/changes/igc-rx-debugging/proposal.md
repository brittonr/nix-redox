## Why

The igcd driver (Intel I225/I226 2.5GbE) initializes on the GMKtec N150, registers its network scheme, and smolnetd discovers the interface — but ping shows 100% packet loss. The RX path, TX path, or link negotiation has a bug preventing actual network traffic. Without diagnostic instrumentation, the driver's internal state (link status register, descriptor ring positions, interrupt causes, packet counters) is invisible, making it impossible to isolate the failure.

## What Changes

- Add runtime diagnostic logging to igcd: link status, IRQ causes, RX/TX descriptor state, packet counters
- Add a `.control` write interface to igcd for on-demand register dumps (write "status" → log register state)
- Enable driver log level override via bootloader env (`DRIVER_PCI_LOG_LEVEL=Debug`)
- Fix the RX path based on diagnostic findings (likely: interrupt register offsets, descriptor writeback format, or RCTL configuration mismatch for I225/I226 vs E1000)
- Verify end-to-end ping and TCP on GMKtec I226-V hardware

## Capabilities

### New Capabilities
- `igc-diagnostics`: Runtime diagnostic output for igcd — link status, IRQ, descriptor ring state, register dumps, packet counters

### Modified Capabilities
- `igc-driver`: Fix RX/TX path bugs identified through diagnostics — correct register offsets, descriptor handling, interrupt acknowledgment, or RCTL/TCTL configuration for I225/I226 hardware

## Impact

- **igcd source**: `nix/pkgs/system/igcd/src/` — add logging to device.rs, possibly new diag.rs module
- **No new dependencies**: uses existing `log` crate and `common::setup_logging` infrastructure
- **Build system**: no changes (igcd already in base workspace)
- **Test hardware**: GMKtec NucBoxG3 Plus (N150, I226-V), accessible via JetKVM
- **Debugging approach**: Redox driver logging goes to stderr (→ logd) and file output (→ `/scheme/logging/net/pci/<name>.log`). Log level controllable via `DRIVER_PCI_LOG_LEVEL` bootloader env. Additionally, serial output is accessible from JetKVM for kernel-level debugging.
