// Bit definitions for Intel I225/I226 (igc family)
// Translated from FreeBSD sys/dev/igc/igc_defines.h

// --- CTRL register bits ---
pub const CTRL_FD: u32 = 1 << 0; // Full Duplex
pub const CTRL_LRST: u32 = 1 << 3; // Link Reset
pub const CTRL_ASDE: u32 = 1 << 5; // Auto-Speed Detection Enable
pub const CTRL_SLU: u32 = 1 << 6; // Set Link Up
pub const CTRL_ILOS: u32 = 1 << 7; // Invert Loss-of-Signal
pub const CTRL_RST: u32 = 1 << 26; // Device Reset
pub const CTRL_VME: u32 = 1 << 30; // VLAN Mode Enable
pub const CTRL_PHY_RST: u32 = 1 << 31; // PHY Reset

// --- STATUS register bits ---
pub const STATUS_FD: u32 = 1 << 0; // Full Duplex
pub const STATUS_LU: u32 = 1 << 1; // Link Up
pub const STATUS_SPEED_MASK: u32 = 0x000000C0;
pub const STATUS_SPEED_10: u32 = 0x00000000;
pub const STATUS_SPEED_100: u32 = 0x00000040;
pub const STATUS_SPEED_1000: u32 = 0x00000080;
pub const STATUS_SPEED_2500: u32 = 0x00200000; // I225/I226 specific

// --- ICR / IMS / IMC interrupt bits ---
pub const ICR_TXDW: u32 = 1 << 0; // TX Descriptor Writeback
pub const ICR_TXQE: u32 = 1 << 1; // TX Queue Empty
pub const ICR_LSC: u32 = 1 << 2; // Link Status Change
pub const ICR_RXDMT0: u32 = 1 << 4; // RX Descriptor Minimum Threshold
pub const ICR_RXT0: u32 = 1 << 7; // RX Timer Interrupt

// --- RCTL register bits ---
pub const RCTL_EN: u32 = 1 << 1; // Receiver Enable
pub const RCTL_UPE: u32 = 1 << 3; // Unicast Promiscuous Enable
pub const RCTL_MPE: u32 = 1 << 4; // Multicast Promiscuous Enable
pub const RCTL_LPE: u32 = 1 << 5; // Long Packet Enable
pub const RCTL_LBM: u32 = 3 << 6; // Loopback Mode
pub const RCTL_BAM: u32 = 1 << 15; // Broadcast Accept Mode
pub const RCTL_BSIZE_2048: u32 = 0 << 16; // Buffer size 2048 (default)
pub const RCTL_BSEX: u32 = 1 << 25; // Buffer Size Extension
pub const RCTL_SECRC: u32 = 1 << 26; // Strip Ethernet CRC

// --- TCTL register bits ---
pub const TCTL_EN: u32 = 1 << 1; // TX Enable
pub const TCTL_PSP: u32 = 1 << 3; // Pad Short Packets
pub const TCTL_CT_SHIFT: u32 = 4; // Collision Threshold shift
pub const TCTL_CT_VAL: u32 = 0x0F << TCTL_CT_SHIFT; // Default CT = 15
pub const TCTL_COLD_SHIFT: u32 = 12; // Collision Distance shift
pub const TCTL_COLD_FD: u32 = 0x40 << TCTL_COLD_SHIFT; // Full Duplex collision distance

// --- EERD (NVM Read) register bits ---
pub const NVM_RW_REG_START: u32 = 1; // Start Read
pub const NVM_RW_ADDR_SHIFT: u32 = 2; // Address Shift
pub const NVM_RW_REG_DONE: u32 = 1 << 1; // Read Done
pub const NVM_RW_REG_DATA: u32 = 16; // Data field starts at bit 16

// --- SRRCTL (Split Receive Control) bits ---
pub const SRRCTL_BSIZEPKT_SHIFT: u32 = 10;
pub const SRRCTL_DESCTYPE_MASK: u32 = 0x0E000000;
pub const SRRCTL_DESCTYPE_ADV_ONEBUF: u32 = 0x02000000;
pub const SRRCTL_DROP_EN: u32 = 0x10000000;

// --- RXDCTL / TXDCTL bits ---
pub const RXDCTL_ENABLE: u32 = 1 << 25;
pub const TXDCTL_ENABLE: u32 = 1 << 25;

// --- Advanced RX descriptor status bits (writeback) ---
pub const RXDADV_STAT_DD: u32 = 1 << 0; // Descriptor Done
pub const RXDADV_STAT_EOP: u32 = 1 << 1; // End of Packet

// --- Advanced TX descriptor command bits ---
pub const ADVTXD_DTYP_DATA: u32 = 0x00300000; // Advanced Data Descriptor
pub const ADVTXD_DCMD_DEXT: u32 = 0x20000000; // Descriptor Extension
pub const ADVTXD_DCMD_RS: u32 = 0x08000000; // Report Status
pub const ADVTXD_DCMD_IFCS: u32 = 0x02000000; // Insert FCS
pub const ADVTXD_DCMD_EOP: u32 = 0x01000000; // End of Packet
pub const ADVTXD_PAYLEN_SHIFT: u32 = 14; // Payload Length shift

// --- Advanced TX descriptor status bits (writeback) ---
pub const ADVTXD_STAT_DD: u32 = 1 << 0; // Descriptor Done

// --- MDIC (PHY) register bits ---
pub const MDIC_DATA_MASK: u32 = 0x0000FFFF;
pub const MDIC_REG_SHIFT: u32 = 16;
pub const MDIC_PHY_SHIFT: u32 = 21;
pub const MDIC_OP_READ: u32 = 0x08000000;
pub const MDIC_OP_WRITE: u32 = 0x04000000;
pub const MDIC_READY: u32 = 0x10000000;
pub const MDIC_ERROR: u32 = 0x40000000;

// --- Packet buffer defaults ---
pub const RXPBS_DEFAULT: u32 = 0x20; // 32KB RX packet buffer
pub const TXPBS_DEFAULT: u32 = 0x14; // 20KB TX packet buffer
