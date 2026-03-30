// Advanced RX and TX descriptor structures for Intel I225/I226
// Translated from FreeBSD igc_defines.h / ixgbe-style union descriptors

// ========== Advanced RX Descriptor ==========

/// Advanced RX descriptor — read format (software → hardware).
/// Software fills pkt_addr with the DMA buffer address.
/// hdr_addr is unused for single-buffer mode (set to 0).
#[derive(Debug, Copy, Clone)]
#[repr(C, packed)]
pub struct AdvRxDescRead {
    pub pkt_addr: u64,
    pub hdr_addr: u64,
}

/// Advanced RX descriptor — writeback format (hardware → software).
/// Hardware fills this after receiving a packet.
#[derive(Debug, Copy, Clone)]
#[repr(C, packed)]
pub struct AdvRxDescWb {
    pub rss_hash: u32,
    pub pkt_info: u32,
    pub status_error: u32,
    pub length: u16,
    pub vlan: u16,
}

/// Advanced RX descriptor — union of read and writeback formats.
/// Both layouts are 16 bytes. Use `read` to set up, `wb` to check results.
#[derive(Copy, Clone)]
#[repr(C, packed)]
pub union AdvRxDesc {
    pub read: AdvRxDescRead,
    pub wb: AdvRxDescWb,
    _align: [u64; 2],
}

// ========== Advanced TX Descriptor ==========

/// Advanced TX descriptor — read format (software → hardware).
/// Software fills buffer_addr, cmd_type_len, and olinfo_status.
#[derive(Debug, Copy, Clone)]
#[repr(C, packed)]
pub struct AdvTxDescRead {
    pub buffer_addr: u64,
    pub cmd_type_len: u32,
    pub olinfo_status: u32,
}

/// Advanced TX descriptor — writeback format (hardware → software).
/// Hardware fills status after transmitting the packet.
#[derive(Debug, Copy, Clone)]
#[repr(C, packed)]
pub struct AdvTxDescWb {
    pub rsvd: u64,
    pub nxtseq_seed: u32,
    pub status: u32,
}

/// Advanced TX descriptor — union of read and writeback formats.
/// Both layouts are 16 bytes.
#[derive(Copy, Clone)]
#[repr(C, packed)]
pub union AdvTxDesc {
    pub read: AdvTxDescRead,
    pub wb: AdvTxDescWb,
    _align: [u64; 2],
}
