## ADDED Requirements

### Requirement: PCI device matching and initialization
The igcd driver must be spawned by pcid-spawner when an I225/I226 PCI device is detected, initialize the hardware, and register a network scheme.

#### Scenario: pcid-spawner detects I226-V
- **WHEN** pcid-spawner enumerates a PCI device with class 0x02 (network), vendor 0x8086, device 0x125C
- **THEN** igcd is spawned with PCID_CLIENT_CHANNEL, maps BAR0, resets the hardware, reads the MAC address, and signals readiness

#### Scenario: pcid-spawner detects I225-V
- **WHEN** pcid-spawner enumerates a PCI device with class 0x02, vendor 0x8086, device 0x15F3
- **THEN** igcd is spawned and initializes identically to I226-V

#### Scenario: unsupported device ID
- **WHEN** pcid-spawner does not find any matching igc device IDs in PCI space
- **THEN** igcd is not spawned; no error, no effect on boot

### Requirement: Hardware reset and PHY initialization
The driver must reset the NIC and bring the integrated PHY to a link-up state, following the I225/I226 initialization sequence from FreeBSD's `igc_i225.c` and `igc_base.c`.

#### Scenario: hardware reset on attach
- **WHEN** igcd starts and maps BAR0
- **THEN** it performs a global reset (CTRL.RST), waits for reset completion, initializes the PHY, configures auto-negotiation for 10/100/1000/2500 Mbps, and sets CTRL.SLU (set link up)

#### Scenario: link establishment
- **WHEN** an Ethernet cable is connected to the I226-V port
- **THEN** the PHY auto-negotiates link speed and the STATUS.LU bit becomes set within 5 seconds

### Requirement: MAC address retrieval
The driver must obtain the NIC's factory MAC address.

#### Scenario: MAC from NVM
- **WHEN** igcd initializes
- **THEN** it reads the MAC address from NVM (EEPROM) via the NVM read sequence from `igc_nvm.c`, or falls back to reading RAL0/RAH0 registers

#### Scenario: MAC address reported to scheme clients
- **WHEN** a process opens the network scheme and reads configuration
- **THEN** the `NetworkAdapter::mac_address()` method returns the 6-byte hardware MAC

### Requirement: DMA descriptor ring setup
The driver must allocate TX and RX descriptor rings in DMA-accessible memory and configure the hardware to use them.

#### Scenario: RX ring initialization
- **WHEN** igcd initializes
- **THEN** it allocates a ring of 256 advanced RX descriptors via `common::dma::Dma`, allocates 256 packet buffers (2KB each), writes descriptor base address to RDBAL0/RDBAH0, ring length to RDLEN0, and sets RDH0=0 / RDT0=255

#### Scenario: TX ring initialization
- **WHEN** igcd initializes
- **THEN** it allocates a ring of 256 advanced TX descriptors via `common::dma::Dma`, writes descriptor base address to TDBAL0/TDBAH0, ring length to TDLEN0, and sets TDH0=0 / TDT0=0

### Requirement: Packet reception
The driver must receive Ethernet frames from the NIC and deliver them to scheme clients.

#### Scenario: single packet received
- **WHEN** the NIC DMA-writes a packet into an RX descriptor and sets the DD (descriptor done) status bit
- **THEN** `read_packet()` copies the packet data to the caller's buffer, advances RDT to recycle the descriptor, and returns `Ok(Some(length))`

#### Scenario: no packets available
- **WHEN** a caller invokes `read_packet()` and no RX descriptors have DD set
- **THEN** `read_packet()` returns `Ok(None)` (non-blocking)

#### Scenario: interrupt-driven notification
- **WHEN** the NIC raises a legacy interrupt (ICR.RXT0) indicating received packets
- **THEN** igcd acknowledges the interrupt (reads ICR), and `NetworkScheme` wakes any blocked readers via fevent

### Requirement: Packet transmission
The driver must accept Ethernet frames from scheme clients and transmit them via the NIC.

#### Scenario: single packet transmitted
- **WHEN** `write_packet(buf)` is called with a valid Ethernet frame
- **THEN** the driver writes the frame into the next available TX descriptor, sets EOP+IFCS+RS command bits, advances TDT, and returns `Ok(length)`

#### Scenario: TX ring full
- **WHEN** `write_packet()` is called but all TX descriptors are in use (DD not set on next descriptor)
- **THEN** the driver returns `Err(EAGAIN)` or blocks until a descriptor becomes available

### Requirement: Interrupt handling
The driver must handle hardware interrupts for RX completion, TX completion, and link status changes.

#### Scenario: RX interrupt
- **WHEN** the NIC signals an interrupt and ICR indicates RXT0 (RX timer)
- **THEN** igcd reads ICR to acknowledge, checks RX descriptors for completed packets, and notifies waiting readers

#### Scenario: link status change interrupt
- **WHEN** ICR indicates LSC (link status change)
- **THEN** igcd reads STATUS.LU and logs the link state transition

### Requirement: Network scheme registration
The driver must register as a Redox network scheme so that smolnetd and user programs can open and use it.

#### Scenario: scheme available after init
- **WHEN** igcd completes initialization
- **THEN** a scheme named `network.<pci_addr>_igc` is registered and accessible at `/scheme/network.<pci_addr>_igc`

#### Scenario: smolnetd discovers interface
- **WHEN** smolnetd scans for network schemes
- **THEN** it discovers the igcd scheme and configures TCP/IP on the interface

### Requirement: Build system integration
The driver must be buildable by the Nix cross-compilation system and included in disk images when configured.

#### Scenario: hardware module selects igcd
- **WHEN** a Redox system configuration includes `networkDrivers = ["igcd"]`
- **THEN** the igcd binary is included in initfs, pcid.toml has the matching PCI entries, and pcid-spawner launches igcd on matching hardware

#### Scenario: PCI registry entries
- **WHEN** the `pcid.nix` PCI registry is evaluated with igcd in allDrivers
- **THEN** it emits TOML entries for all supported I225/I226 device IDs under vendor 0x8086, class 0x02
