## 1. Project scaffold and build system

- [x] 1.1 Create `igcd/` crate with Cargo.toml, config.toml, src/main.rs, src/device.rs — mirror e1000d structure exactly. Cargo.toml deps: `driver-network`, `pcid` (for pcid_interface), `common`, `daemon`, `redox_event`, `libredox`, `redox_syscall`, `log`, `bitflags`. config.toml: `ids = { 0x8086 = [0x15F2, 0x15F3, 0x125B, 0x125C, 0x125D, 0x3100] }` (upstream format). main.rs: copy e1000d's main.rs verbatim and change names/types
- [x] 1.2 Add igcd to `pcid.nix` PCI registry — one entry per device ID under vendor 0x8086, class 0x02: 0x15F2 (I225-LM), 0x15F3 (I225-V), 0x125B (I226-LM), 0x125C (I226-V), 0x125D (I226-IT), 0x3100 (I225-K). Note: our Nix pcid.nix uses `device = "0xNNNN"` fields; upstream config.toml uses `ids = { vendor = [devs] }` — both formats work with pcid-spawner
- [x] 1.3 Add `igcd` to `hardware.nix` networkDriver enum
- [x] 1.4 Add igcd package derivation to flake.nix (cross-compiled Redox crate, same pattern as e1000d)
- [x] 1.5 Verify igcd builds with `nix build .#igcd` and the binary is included in initfs when `networkDrivers = ["igcd"]`

## 2. Register definitions and hardware abstraction

- [x] 2.1 Create `src/regs.rs` — translate register offsets from FreeBSD `igc_regs.h` (CTRL, STATUS, ICR, IMS, IMC, RCTL, TCTL, RDBAL/RDBAH/RDLEN/RDH/RDT for queue 0, TDBAL/TDBAH/TDLEN/TDH/TDT for queue 0, RAL0/RAH0, MTA, MDIC, EECD/EERD, RXPBS, TXPBS, GPRC/GPTC stats)
- [x] 2.2 Create `src/hw.rs` — register read/write accessors via MMIO BAR0 pointer (volatile read/write, same pattern as e1000d's `read`/`write` methods). Include `read_reg(u32) -> u32` and `write_reg(u32, u32)`
- [x] 2.3 Create `src/defines.rs` — translate bit definitions from FreeBSD `igc_defines.h` for CTRL, STATUS, RCTL, TCTL, interrupt cause bits, descriptor status bits

## 3. NVM and MAC address

- [x] 3.1 Implement NVM read in `src/nvm.rs` — translate EERD-based NVM word read from FreeBSD `igc_nvm.c` (`igc_read_nvm_eerd`). Polls EERD.DONE bit after writing address+start to EERD register
- [x] 3.2 Implement `read_mac_address()` — read 3 NVM words (offsets 0x00-0x02) and assemble 6-byte MAC. Fallback: read RAL0/RAH0 if NVM read fails
- [x] 3.3 Test MAC address read on GMKtec I226-V — verify matches `e0:51:d8:17:18:35` (from NixOS `ip link`)

## 4. Hardware reset and PHY init

- [x] 4.1 Implement global reset — write CTRL.RST, wait for completion (poll CTRL.RST clear), disable interrupts (write IMC=0xFFFFFFFF), read ICR to clear pending. Reference: FreeBSD `igc_reset_hw_base()` in `igc_base.c`
- [x] 4.2 Implement PHY init — translate `igc_init_hw_i225()` from FreeBSD `igc_i225.c`. Key steps: PHY reset via MDIC, configure auto-negotiation advertisement (10/100/1000/2500), set CTRL.SLU
- [x] 4.3 Implement link status check — read STATUS register, check LU (link up) bit, log speed from STATUS.SPEED field
- [x] 4.4 Test hardware reset and link on GMKtec — verify link comes up with cable connected, STATUS.LU set

## 5. DMA descriptor rings

- [x] 5.1 Define advanced RX descriptor struct in `src/desc.rs` — translate from FreeBSD `igc_defines.h`. Read format: `buffer_addr: u64, hdr_addr: u64`. Writeback format: status, length, VLAN, etc.
- [x] 5.2 Define advanced TX descriptor struct — context descriptor and data descriptor formats. Key fields: `buffer_addr`, `cmd_type_len`, `olinfo_status`
- [x] 5.3 Implement RX ring init — allocate 256 descriptors + 256 packet buffers (2KB each) via `Dma::zeroed()`. Write RDBAL0/RDBAH0/RDLEN0, configure RXPBS (RX packet buffer size), set SRRCTL0 (buffer size, descriptor type = advanced), set RDH0=0 / RDT0=255, enable RCTL (EN+BAM+SECRC, buffer size 2KB)
- [x] 5.4 Implement TX ring init — allocate 256 descriptors via `Dma::zeroed()`. Write TDBAL0/TDBAH0/TDLEN0, configure TXPBS, set TDH0=0 / TDT0=0, enable TCTL (EN+PSP, collision threshold, cold)

## 6. Packet RX/TX and NetworkAdapter trait

- [x] 6.1 Implement `NetworkAdapter::read_packet()` — check RX descriptor DD bit at current head, copy packet from DMA buffer to caller buf, advance head, bump RDT to recycle. Return `Ok(None)` if no DD
- [x] 6.2 Implement `NetworkAdapter::write_packet()` — write frame to next TX descriptor buffer, set advanced TX descriptor fields (DTYP=data, DCMD=EOP+IFCS+RS, PAYLEN), advance TDT. Check previous descriptor DD for ring-full detection
- [x] 6.3 Implement `NetworkAdapter::available_for_read()` — scan RX descriptors from head, count consecutive DD-set entries
- [x] 6.4 Implement `NetworkAdapter::mac_address()` — return cached MAC from init

## 7. Interrupt handling and main loop

- [x] 7.1 Implement interrupt setup — configure IMS for RXT0 (RX timer), TXDW (TX writeback), LSC (link status change). Map legacy IRQ via `pcid_interface` legacy_interrupt_line + irq_handle
- [x] 7.2 Implement IRQ handler — read ICR to acknowledge and determine cause. On RXT0: signal scheme to wake blocked readers. On LSC: log link state. On TXDW: optional TX completion bookkeeping
- [x] 7.3 Wire main.rs — `pcid_interface::pci_daemon(daemon)` entry, `pcid_handle.map_bar(0)` for MMIO, `NetworkScheme::new(|| Igc::new(address), daemon, format!("network.{name}"))`, `EventQueue` with `Source::Irq` + `Source::Scheme`, `setrens(0, 0)` to enter null namespace, `scheme.tick()` on each event. Copy e1000d/ixgbed pattern exactly — the main.rs is nearly identical across all Redox net drivers

## 8. Integration and testing

- [x] 8.1 Add igcd to GMKtec N150 configuration: `networkDrivers = ["igcd"]`
- [x] 8.2 Build disk image, boot on GMKtec via JetKVM virtual media
- [x] 8.3 Verify igcd starts — check fbbootlog for igcd init messages, MAC address printout, link status
- [ ] 8.4 Test ping — configure IP via smolnetd/dhcpd or static, ping gateway from Redox shell
- [ ] 8.5 Test TCP — use `redox-curl` to fetch a URL, verify data transfer
- [x] 8.6 Update GMKtec example configuration.nix with working network config
