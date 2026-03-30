// Hardware register access for Intel I225/I226
// MMIO BAR0 volatile read/write, same pattern as e1000d

use std::ptr;

/// Read a 32-bit register at `base + offset` via volatile MMIO.
///
/// # Safety
/// `base` must point to a valid MMIO mapping of the NIC BAR0.
/// `offset` must be a valid register offset within the BAR.
#[inline]
pub unsafe fn read_reg(base: usize, offset: u32) -> u32 {
    ptr::read_volatile((base + offset as usize) as *const u32)
}

/// Write a 32-bit value to register at `base + offset` via volatile MMIO.
/// Returns the value read back after writing (write-then-read pattern).
///
/// # Safety
/// `base` must point to a valid MMIO mapping of the NIC BAR0.
/// `offset` must be a valid register offset within the BAR.
#[inline]
pub unsafe fn write_reg(base: usize, offset: u32, value: u32) -> u32 {
    ptr::write_volatile((base + offset as usize) as *mut u32, value);
    ptr::read_volatile((base + offset as usize) as *const u32)
}

/// Set bits in a register (read-modify-write).
///
/// # Safety
/// Same requirements as `read_reg`/`write_reg`.
#[inline]
pub unsafe fn set_flag(base: usize, offset: u32, flag: u32) {
    let val = read_reg(base, offset);
    write_reg(base, offset, val | flag);
}

/// Clear bits in a register (read-modify-write).
///
/// # Safety
/// Same requirements as `read_reg`/`write_reg`.
#[inline]
pub unsafe fn clear_flag(base: usize, offset: u32, flag: u32) {
    let val = read_reg(base, offset);
    write_reg(base, offset, val & !flag);
}
