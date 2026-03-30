## 1. Add diagnostic logging infrastructure

- [ ] 1.1 Add debug/trace logging to `device.rs::init()` — log CTRL, STATUS before/after reset; SRRCTL, RDBAL, RDBAH, RDLEN, TDBAL, TDBAH, TDLEN after ring setup; RCTL, TCTL values written; STATUS after CTRL.SLU set
- [ ] 1.2 Add debug logging to `device.rs::irq()` — log ICR value with decoded cause bits (RXT0=bit7, TXDW=bit0, LSC=bit2, RXDMT0=bit4)
- [ ] 1.3 Add debug logging to `read_packet()` — log RX descriptor index, DD bit, status_error field, packet length; at trace level log first 14 bytes (ethernet header: dst MAC, src MAC, ethertype)
- [ ] 1.4 Add debug logging to `write_packet()` — log TX descriptor index, cmd_type_len, TDT value, packet length; at trace level log first 14 bytes
- [ ] 1.5 Add periodic heartbeat to `irq()` — every 1000 interrupts, log at info level: STATUS, RDH0, RDT0, TDH0, TDT0, total interrupt count, total RX/TX packet counts
- [ ] 1.6 Add `irq_count`, `rx_count`, `tx_count` fields to Igc struct for heartbeat counters

## 2. Verify and fix descriptor struct layout

- [ ] 2.1 Cross-check `AdvRxDescWb` struct against Intel I225/I226 datasheet and FreeBSD `igc_defines.h` — verify field offsets: rss_hash at 0, pkt_info at 4, status_error at 8, length at 12, vlan at 14. Total size must be 16 bytes.
- [ ] 2.2 Cross-check `AdvTxDescRead` struct against datasheet — verify: buffer_addr at 0, cmd_type_len at 8, olinfo_status at 12. Total size must be 16 bytes.
- [ ] 2.3 Add `static_assert!(size_of::<AdvRxDesc>() == 16)` and `static_assert!(size_of::<AdvTxDesc>() == 16)` to desc.rs using `static_assertions` crate or `const _: () = assert!(...)` blocks

## 3. Verify and fix initialization sequence

- [ ] 3.1 Move CTRL.SLU set to AFTER RX/TX ring setup and interrupt enable — current code sets SLU before rings are ready, which can cause the NIC to receive frames before descriptors are posted
- [ ] 3.2 Add RCTL_UPE (unicast promiscuous) flag during init for debugging — bypass MAC filter to rule out MAC address mismatch as cause of packet loss. Log whether promiscuous mode is enabled.
- [ ] 3.3 Verify RXDCTL/TXDCTL ENABLE polling — add timeout with error log if enable doesn't take effect within 100ms. Current code polls 100 iterations with 1ms sleep but doesn't log failure.
- [ ] 3.4 Add post-init register dump — after full init, read back and log: CTRL, STATUS, RCTL, TCTL, RXDCTL0, TXDCTL0, SRRCTL0, IMS, RAL0, RAH0. Compare written vs read-back values.

## 4. Build, boot, and capture diagnostic output

- [ ] 4.1 Set `DRIVER_PCI_LOG_LEVEL=Debug` in bare-metal-gmktec profile bootloader environment (or add to igcd's setup_logging call to force debug level)
- [ ] 4.2 Build disk image with debug igcd, upload to JetKVM, boot GMKtec
- [ ] 4.3 Read igcd log output — check `/scheme/logging/net/pci/` for log files, or read from serial output via JetKVM. Capture: link status, interrupt firing, RX/TX descriptor state.
- [ ] 4.4 Run `ping 1.1.1.1` and capture diagnostic output — identify whether: (a) TX descriptors advance (TDH moves), (b) interrupts fire (ICR non-zero), (c) RX descriptors receive data (DD set), (d) link is up (STATUS.LU)

## 5. Fix identified RX/TX bugs

- [ ] 5.1 Based on diagnostic output, identify root cause — likely one of: (a) link not up (STATUS.LU=0), (b) TX frames not sent (TDH doesn't advance), (c) RX frames not received (no DD bits set), (d) interrupts not firing (ICR always 0), (e) MAC filter rejecting (RAL0/RAH0 mismatch)
- [ ] 5.2 Implement fix for identified root cause
- [ ] 5.3 Rebuild, boot, verify ping works — expect: ICMP echo replies with round-trip times
- [ ] 5.4 Test TCP — run `curl http://<host>` or equivalent, verify data transfer

## 6. Cleanup and verify

- [ ] 6.1 Remove RCTL_UPE promiscuous override if MAC filter works correctly
- [ ] 6.2 Set default log level back to Info (keep debug/trace logging in code for future use)
- [ ] 6.3 Final boot test — verify ping and TCP still work with production log level
- [ ] 6.4 Update napkin.md with any new lessons learned about I225/I226 hardware or Redox driver debugging
