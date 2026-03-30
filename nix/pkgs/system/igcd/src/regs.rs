// Register offsets for Intel I225/I226 (igc family)
// Translated from FreeBSD sys/dev/igc/igc_regs.h

// General
pub const CTRL: u32 = 0x0000;
pub const STATUS: u32 = 0x0008;

// EEPROM/NVM
pub const EECD: u32 = 0x0010;
pub const EERD: u32 = 0x0014;

// PHY
pub const MDIC: u32 = 0x0020;

// Flow control (unused, zeroed on init)
pub const FCAL: u32 = 0x0028;
pub const FCAH: u32 = 0x002C;
pub const FCT: u32 = 0x0030;
pub const FCTTV: u32 = 0x0170;

// Interrupt registers (I225/I226 offsets, NOT legacy E1000)
pub const ICR: u32 = 0x01500;
pub const ICS: u32 = 0x01504;
pub const IMS: u32 = 0x01508;
pub const IMC: u32 = 0x0150C;

// RX control
pub const RCTL: u32 = 0x0100;

// TX control
pub const TCTL: u32 = 0x0400;

// RX queue 0 descriptor ring
pub const RDBAL0: u32 = 0xC000;
pub const RDBAH0: u32 = 0xC004;
pub const RDLEN0: u32 = 0xC008;
pub const SRRCTL0: u32 = 0xC00C;
pub const RDH0: u32 = 0xC010;
pub const RDT0: u32 = 0xC018;
pub const RXDCTL0: u32 = 0xC028;

// TX queue 0 descriptor ring
pub const TDBAL0: u32 = 0xE000;
pub const TDBAH0: u32 = 0xE004;
pub const TDLEN0: u32 = 0xE008;
pub const TDH0: u32 = 0xE010;
pub const TDT0: u32 = 0xE018;
pub const TXDCTL0: u32 = 0xE028;

// Receive address (MAC)
pub const RAL0: u32 = 0x5400;
pub const RAH0: u32 = 0x5404;

// Multicast table array (128 entries)
pub const MTA: u32 = 0x5200;

// Packet buffer sizing
pub const RXPBS: u32 = 0x2404;
pub const TXPBS: u32 = 0x3404;

// Statistics (read-on-clear)
pub const GPRC: u32 = 0x04074;
pub const GPTC: u32 = 0x04080;
