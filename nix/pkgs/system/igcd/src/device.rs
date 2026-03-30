// Intel I225/I226 (igc) 2.5GbE network driver for Redox OS
//
// Implements the NetworkAdapter trait from driver-network.
// Register offsets in regs.rs, bit definitions in defines.rs,
// descriptor formats in desc.rs, NVM access in nvm.rs.

use std::convert::TryInto;
use std::fmt::Write as FmtWrite;
use std::{cmp, mem, slice, thread, time};

use driver_network::NetworkAdapter;
use syscall::error::Result;

use common::dma::Dma;

use crate::defines::*;
use crate::desc::{AdvRxDesc, AdvTxDesc};
use crate::hw;
use crate::nvm;
use crate::regs;

const RING_SIZE: usize = 256;
const BUF_SIZE: usize = 2048;

pub struct Igc {
    base: usize,
    mac_address: [u8; 6],
    receive_buffer: [Dma<[u8; BUF_SIZE]>; RING_SIZE],
    receive_ring: Dma<[AdvRxDesc; RING_SIZE]>,
    receive_index: usize,
    transmit_buffer: [Dma<[u8; BUF_SIZE]>; RING_SIZE],
    transmit_ring: Dma<[AdvTxDesc; RING_SIZE]>,
    transmit_ring_free: usize,
    transmit_index: usize,
    transmit_clean_index: usize,
}

fn wrap_ring(index: usize, ring_size: usize) -> usize {
    (index + 1) & (ring_size - 1)
}

fn dma_array<T, const N: usize>() -> Result<[Dma<T>; N]> {
    Ok((0..N)
        .map(|_| Ok(unsafe { Dma::zeroed()?.assume_init() }))
        .collect::<Result<Vec<_>>>()?
        .try_into()
        .unwrap_or_else(|_| unreachable!()))
}

// === NetworkAdapter trait implementation ===

impl NetworkAdapter for Igc {
    fn mac_address(&mut self) -> [u8; 6] {
        self.mac_address
    }

    fn diagnostic_info(&mut self) -> Vec<u8> {
        unsafe { self.build_diag_string() }.into_bytes()
    }

    fn available_for_read(&mut self) -> usize {
        let desc = unsafe {
            &*(self.receive_ring.as_ptr().add(self.receive_index) as *const AdvRxDesc)
        };
        let status = unsafe { desc.wb.status_error };
        if status & RXDADV_STAT_DD != 0 {
            return unsafe { desc.wb.length } as usize;
        }
        0
    }

    fn read_packet(&mut self, buf: &mut [u8]) -> Result<Option<usize>> {
        let desc = unsafe {
            &mut *(self.receive_ring.as_ptr().add(self.receive_index) as *mut AdvRxDesc)
        };
        let status = unsafe { desc.wb.status_error };

        if status & RXDADV_STAT_DD != 0 {
            let pkt_len = unsafe { desc.wb.length } as usize;
            let data = &self.receive_buffer[self.receive_index][..pkt_len];
            let i = cmp::min(buf.len(), data.len());
            buf[..i].copy_from_slice(&data[..i]);

            // Re-arm descriptor: set pkt_addr back to the DMA buffer
            desc.read.pkt_addr = self.receive_buffer[self.receive_index].physical() as u64;
            desc.read.hdr_addr = 0;

            // Advance RDT to recycle this descriptor
            unsafe { hw::write_reg(self.base, regs::RDT0, self.receive_index as u32) };
            self.receive_index = wrap_ring(self.receive_index, self.receive_ring.len());

            return Ok(Some(i));
        }

        Ok(None)
    }

    fn write_packet(&mut self, buf: &[u8]) -> Result<usize> {
        // Reclaim completed TX descriptors
        if self.transmit_ring_free == 0 {
            loop {
                let desc = unsafe {
                    &*(self.transmit_ring.as_ptr().add(self.transmit_clean_index)
                        as *const AdvTxDesc)
                };

                if (unsafe { desc.wb.status } & ADVTXD_STAT_DD) != 0 {
                    self.transmit_clean_index =
                        wrap_ring(self.transmit_clean_index, self.transmit_ring.len());
                    self.transmit_ring_free += 1;
                } else if self.transmit_ring_free > 0 {
                    break;
                }

                if self.transmit_ring_free >= self.transmit_ring.len() {
                    break;
                }
            }
        }

        let desc = unsafe {
            &mut *(self.transmit_ring.as_ptr().add(self.transmit_index) as *mut AdvTxDesc)
        };

        // Copy packet data to DMA buffer
        let data = unsafe {
            slice::from_raw_parts_mut(
                self.transmit_buffer[self.transmit_index].as_ptr() as *mut u8,
                cmp::min(buf.len(), self.transmit_buffer[self.transmit_index].len()),
            )
        };
        let i = cmp::min(buf.len(), data.len());
        data[..i].copy_from_slice(&buf[..i]);

        // Set advanced TX descriptor fields
        desc.read.cmd_type_len = ADVTXD_DCMD_EOP
            | ADVTXD_DCMD_RS
            | ADVTXD_DCMD_IFCS
            | ADVTXD_DCMD_DEXT
            | ADVTXD_DTYP_DATA
            | i as u32;

        desc.read.olinfo_status = (i as u32) << ADVTXD_PAYLEN_SHIFT;

        self.transmit_index = wrap_ring(self.transmit_index, self.transmit_ring.len());
        self.transmit_ring_free -= 1;

        // Bump TDT to tell hardware about the new descriptor
        unsafe { hw::write_reg(self.base, regs::TDT0, self.transmit_index as u32) };

        Ok(i)
    }
}

// === Device initialization ===

impl Igc {
    pub unsafe fn new(base: usize) -> Result<Self> {
        #[rustfmt::skip]
        let mut device = Igc {
            base,
            mac_address: [0; 6],
            receive_buffer: dma_array()?,
            receive_ring: Dma::zeroed()?.assume_init(),
            receive_index: 0,
            transmit_buffer: dma_array()?,
            transmit_ring: Dma::zeroed()?.assume_init(),
            transmit_ring_free: RING_SIZE,
            transmit_index: 0,
            transmit_clean_index: 0,
        };

        device.init();

        Ok(device)
    }

    /// Check for pending interrupts. Returns true if any interrupt cause is set.
    pub unsafe fn irq(&self) -> bool {
        let icr = hw::read_reg(self.base, regs::ICR);
        if icr != 0 {
            // Log link status changes
            if icr & ICR_LSC != 0 {
                self.log_link_status();
            }
            true
        } else {
            false
        }
    }

    /// Main initialization sequence.
    unsafe fn init(&mut self) {
        // 1. Global reset
        self.reset();

        // 2. Read MAC address (NVM with RAL/RAH fallback)
        self.mac_address = nvm::read_mac_address(self.base);
        log::info!(
            "MAC: {:02X}:{:02X}:{:02X}:{:02X}:{:02X}:{:02X}",
            self.mac_address[0],
            self.mac_address[1],
            self.mac_address[2],
            self.mac_address[3],
            self.mac_address[4],
            self.mac_address[5],
        );

        // 3. Write MAC to RAL0/RAH0 (ensure hardware uses it)
        let mac_low = u32::from(self.mac_address[0])
            | (u32::from(self.mac_address[1]) << 8)
            | (u32::from(self.mac_address[2]) << 16)
            | (u32::from(self.mac_address[3]) << 24);
        let mac_high = u32::from(self.mac_address[4])
            | (u32::from(self.mac_address[5]) << 8)
            | (1 << 31); // AV (Address Valid) bit
        hw::write_reg(self.base, regs::RAL0, mac_low);
        hw::write_reg(self.base, regs::RAH0, mac_high);

        // 4. Clear multicast table
        for i in 0..128 {
            hw::write_reg(self.base, regs::MTA + i * 4, 0);
        }

        // 5. No flow control
        hw::write_reg(self.base, regs::FCAL, 0);
        hw::write_reg(self.base, regs::FCAH, 0);
        hw::write_reg(self.base, regs::FCT, 0);
        hw::write_reg(self.base, regs::FCTTV, 0);

        // 6. Configure packet buffer sizes
        hw::write_reg(self.base, regs::RXPBS, RXPBS_DEFAULT);
        hw::write_reg(self.base, regs::TXPBS, TXPBS_DEFAULT);

        // 7. Set up descriptor rings
        self.init_rx();
        self.init_tx();

        // 8. Enable interrupts
        self.init_interrupts();

        // 9. Enable link
        hw::set_flag(self.base, regs::CTRL, CTRL_SLU | CTRL_ASDE);
        hw::clear_flag(self.base, regs::CTRL, CTRL_LRST | CTRL_PHY_RST | CTRL_ILOS);

        // 10. Wait for link
        self.wait_for_link();

        // 11. Post-init register dump
        let s = hw::read_reg(self.base, regs::STATUS);
        log::info!("DIAG CTRL={:#010X} STATUS={:#010X} LU={} RCTL={:#010X} TCTL={:#010X}",
            hw::read_reg(self.base, regs::CTRL), s, s & STATUS_LU != 0,
            hw::read_reg(self.base, regs::RCTL), hw::read_reg(self.base, regs::TCTL));
        log::info!("DIAG RDH={} RDT={} TDH={} TDT={} RAL0={:#010X} RAH0={:#010X}",
            hw::read_reg(self.base, regs::RDH0), hw::read_reg(self.base, regs::RDT0),
            hw::read_reg(self.base, regs::TDH0), hw::read_reg(self.base, regs::TDT0),
            hw::read_reg(self.base, regs::RAL0), hw::read_reg(self.base, regs::RAH0));
    }

    /// Perform a global device reset.
    unsafe fn reset(&self) {
        // Disable interrupts first
        hw::write_reg(self.base, regs::IMC, 0xFFFFFFFF);

        // Write CTRL.RST
        hw::set_flag(self.base, regs::CTRL, CTRL_RST);

        // Wait for reset to complete (CTRL.RST clears itself)
        for _ in 0..100 {
            thread::sleep(time::Duration::from_millis(10));
            if hw::read_reg(self.base, regs::CTRL) & CTRL_RST == 0 {
                break;
            }
        }

        // Post-reset delay
        thread::sleep(time::Duration::from_millis(20));

        // Disable interrupts again after reset
        hw::write_reg(self.base, regs::IMC, 0xFFFFFFFF);

        // Clear any pending interrupt causes
        hw::read_reg(self.base, regs::ICR);

        log::debug!("Reset complete, CTRL={:#010X}", hw::read_reg(self.base, regs::CTRL));
    }

    /// Initialize RX descriptor ring and enable receiver.
    unsafe fn init_rx(&mut self) {
        // Set up SRRCTL: advanced one-buffer descriptors, 2KB buffer size
        let bsizepkt = BUF_SIZE / 1024; // in KB units
        let srrctl = (bsizepkt as u32) << SRRCTL_BSIZEPKT_SHIFT
            | SRRCTL_DESCTYPE_ADV_ONEBUF
            | SRRCTL_DROP_EN;
        hw::write_reg(self.base, regs::SRRCTL0, srrctl);

        // Point each RX descriptor to its DMA buffer
        for i in 0..self.receive_ring.len() {
            self.receive_ring[i].read.pkt_addr = self.receive_buffer[i].physical() as u64;
            self.receive_ring[i].read.hdr_addr = 0;
        }

        // Set ring base address
        hw::write_reg(
            self.base,
            regs::RDBAH0,
            ((self.receive_ring.physical() as u64) >> 32) as u32,
        );
        hw::write_reg(self.base, regs::RDBAL0, self.receive_ring.physical() as u32);

        // Set ring length (bytes)
        hw::write_reg(
            self.base,
            regs::RDLEN0,
            (self.receive_ring.len() * mem::size_of::<AdvRxDesc>()) as u32,
        );

        // Set head to 0 (tail set AFTER queue enable per I225/I226 spec)
        hw::write_reg(self.base, regs::RDH0, 0);

        // Enable RX queue
        hw::set_flag(self.base, regs::RXDCTL0, RXDCTL_ENABLE);

        // Wait for queue enable
        for _ in 0..100 {
            if hw::read_reg(self.base, regs::RXDCTL0) & RXDCTL_ENABLE != 0 {
                break;
            }
            thread::sleep(time::Duration::from_millis(1));
        }

        // Enable receiver: accept broadcast, strip CRC, 2KB buffer
        hw::write_reg(
            self.base,
            regs::RCTL,
            RCTL_EN | RCTL_BAM | RCTL_SECRC | RCTL_BSIZE_2048,
        );

        // Set tail AFTER queue and receiver are enabled (I225/I226 ignores
        // RDT writes before RXDCTL.ENABLE is set)
        hw::write_reg(self.base, regs::RDT0, (self.receive_ring.len() - 1) as u32);

        log::debug!("RX ring initialized: {} descriptors, {}B buffers", RING_SIZE, BUF_SIZE);
    }

    /// Initialize TX descriptor ring and enable transmitter.
    unsafe fn init_tx(&mut self) {
        // Point each TX descriptor to its DMA buffer
        for i in 0..self.transmit_ring.len() {
            self.transmit_ring[i].read.buffer_addr =
                self.transmit_buffer[i].physical() as u64;
        }

        // Set ring base address
        hw::write_reg(
            self.base,
            regs::TDBAH0,
            ((self.transmit_ring.physical() as u64) >> 32) as u32,
        );
        hw::write_reg(self.base, regs::TDBAL0, self.transmit_ring.physical() as u32);

        // Set ring length (bytes)
        hw::write_reg(
            self.base,
            regs::TDLEN0,
            (self.transmit_ring.len() * mem::size_of::<AdvTxDesc>()) as u32,
        );

        // Set head to 0 (tail set AFTER queue enable)
        hw::write_reg(self.base, regs::TDH0, 0);

        // Enable TX queue
        hw::set_flag(self.base, regs::TXDCTL0, TXDCTL_ENABLE);

        // Wait for queue enable
        for _ in 0..100 {
            if hw::read_reg(self.base, regs::TXDCTL0) & TXDCTL_ENABLE != 0 {
                break;
            }
            thread::sleep(time::Duration::from_millis(1));
        }

        // Enable transmitter: pad short packets, collision thresholds for full duplex
        hw::write_reg(
            self.base,
            regs::TCTL,
            TCTL_EN | TCTL_PSP | TCTL_CT_VAL | TCTL_COLD_FD,
        );

        // TX ring starts empty — set tail after queue enable
        hw::write_reg(self.base, regs::TDT0, 0);

        log::debug!("TX ring initialized: {} descriptors", RING_SIZE);
    }

    /// Set up interrupt mask for RX, TX, and link status change.
    unsafe fn init_interrupts(&self) {
        // Clear pending interrupts
        hw::read_reg(self.base, regs::ICR);

        // Enable: RX timer, TX writeback, link status change
        hw::write_reg(
            self.base,
            regs::IMS,
            ICR_RXT0 | ICR_TXDW | ICR_LSC | ICR_RXDMT0,
        );

        log::debug!("Interrupts enabled: RXT0|TXDW|LSC|RXDMT0");
    }

    /// Wait for link up with timeout.
    unsafe fn wait_for_link(&self) {
        log::info!("Waiting for link...");
        for _ in 0..50 {
            let status = hw::read_reg(self.base, regs::STATUS);
            if status & STATUS_LU != 0 {
                self.log_link_status();
                return;
            }
            thread::sleep(time::Duration::from_millis(100));
        }
        log::warn!("Link did not come up after 5s (STATUS={:#010X})", hw::read_reg(self.base, regs::STATUS));
    }

    /// Build register dump string for the diag scheme path.
    unsafe fn build_diag_string(&self) -> String {
        let mut s = String::with_capacity(1024);
        let status = hw::read_reg(self.base, regs::STATUS);
        let ctrl = hw::read_reg(self.base, regs::CTRL);
        let _ = writeln!(s, "CTRL={:#010X}", ctrl);
        let _ = writeln!(s, "STATUS={:#010X}", status);
        let _ = writeln!(s, "Link={}", if status & STATUS_LU != 0 { "UP" } else { "DOWN" });
        let _ = writeln!(s, "Speed={}", if status & STATUS_SPEED_2500 != 0 { "2500" } else {
            match status & STATUS_SPEED_MASK {
                STATUS_SPEED_10 => "10", STATUS_SPEED_100 => "100",
                STATUS_SPEED_1000 => "1000", _ => "?",
            }
        });
        let _ = writeln!(s, "RCTL={:#010X}", hw::read_reg(self.base, regs::RCTL));
        let _ = writeln!(s, "TCTL={:#010X}", hw::read_reg(self.base, regs::TCTL));
        let _ = writeln!(s, "IMS={:#010X}", hw::read_reg(self.base, regs::IMS));
        let _ = writeln!(s, "RXDCTL0={:#010X}", hw::read_reg(self.base, regs::RXDCTL0));
        let _ = writeln!(s, "TXDCTL0={:#010X}", hw::read_reg(self.base, regs::TXDCTL0));
        let _ = writeln!(s, "SRRCTL0={:#010X}", hw::read_reg(self.base, regs::SRRCTL0));
        let _ = writeln!(s, "RDH0={}", hw::read_reg(self.base, regs::RDH0));
        let _ = writeln!(s, "RDT0={}", hw::read_reg(self.base, regs::RDT0));
        let _ = writeln!(s, "TDH0={}", hw::read_reg(self.base, regs::TDH0));
        let _ = writeln!(s, "TDT0={}", hw::read_reg(self.base, regs::TDT0));
        let _ = writeln!(s, "RAL0={:#010X}", hw::read_reg(self.base, regs::RAL0));
        let _ = writeln!(s, "RAH0={:#010X}", hw::read_reg(self.base, regs::RAH0));
        let _ = writeln!(s, "RXPBS={:#010X}", hw::read_reg(self.base, regs::RXPBS));
        let _ = writeln!(s, "TXPBS={:#010X}", hw::read_reg(self.base, regs::TXPBS));
        let _ = writeln!(s, "ICR={:#010X}", hw::read_reg(self.base, regs::ICR));
        let _ = writeln!(s, "MAC={:02X}:{:02X}:{:02X}:{:02X}:{:02X}:{:02X}",
            self.mac_address[0], self.mac_address[1], self.mac_address[2],
            self.mac_address[3], self.mac_address[4], self.mac_address[5]);
        s
    }

    /// Log the current link speed.
    unsafe fn log_link_status(&self) {
        let status = hw::read_reg(self.base, regs::STATUS);
        if status & STATUS_LU != 0 {
            let speed = if status & STATUS_SPEED_2500 != 0 {
                "2500 Mb/s"
            } else {
                match status & STATUS_SPEED_MASK {
                    STATUS_SPEED_10 => "10 Mb/s",
                    STATUS_SPEED_100 => "100 Mb/s",
                    STATUS_SPEED_1000 => "1000 Mb/s",
                    _ => "unknown",
                }
            };
            log::info!("Link up at {}", speed);
        } else {
            log::info!("Link down");
        }
    }
}
