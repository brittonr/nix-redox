// NVM (EEPROM) read for Intel I225/I226
// Translated from FreeBSD igc_nvm.c (igc_read_nvm_eerd)

use crate::defines;
use crate::hw;
use crate::regs;

/// Read a single 16-bit word from NVM via the EERD register.
///
/// # Safety
/// `base` must point to a valid MMIO BAR0 mapping.
pub unsafe fn read_nvm_word(base: usize, offset: u16) -> Option<u16> {
    // Write address and start bit to EERD
    let eerd_val = ((offset as u32) << defines::NVM_RW_ADDR_SHIFT) | defines::NVM_RW_REG_START;
    hw::write_reg(base, regs::EERD, eerd_val);

    // Poll for completion (DONE bit)
    for _ in 0..1000 {
        let val = hw::read_reg(base, regs::EERD);
        if val & defines::NVM_RW_REG_DONE != 0 {
            return Some((val >> defines::NVM_RW_REG_DATA) as u16);
        }
        // Small delay between polls
        core::hint::spin_loop();
    }

    None // Timed out
}

/// Read the 6-byte MAC address from NVM (words 0-2).
/// Falls back to reading RAL0/RAH0 registers if NVM read fails.
///
/// # Safety
/// `base` must point to a valid MMIO BAR0 mapping.
pub unsafe fn read_mac_address(base: usize) -> [u8; 6] {
    // Try NVM first: words 0, 1, 2 contain the MAC address
    if let (Some(w0), Some(w1), Some(w2)) = (
        read_nvm_word(base, 0),
        read_nvm_word(base, 1),
        read_nvm_word(base, 2),
    ) {
        let mac = [
            w0 as u8,
            (w0 >> 8) as u8,
            w1 as u8,
            (w1 >> 8) as u8,
            w2 as u8,
            (w2 >> 8) as u8,
        ];

        // Validate: not all zeros and not all ones
        if mac != [0; 6] && mac != [0xFF; 6] {
            return mac;
        }
    }

    log::warn!("NVM MAC read failed, falling back to RAL0/RAH0");

    // Fallback: read from Receive Address registers (BIOS programs these)
    let low = hw::read_reg(base, regs::RAL0);
    let high = hw::read_reg(base, regs::RAH0);
    [
        low as u8,
        (low >> 8) as u8,
        (low >> 16) as u8,
        (low >> 24) as u8,
        high as u8,
        (high >> 8) as u8,
    ]
}
