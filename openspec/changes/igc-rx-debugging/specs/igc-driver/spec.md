## MODIFIED Requirements

### Requirement: Hardware initialization order
The igcd driver must follow the correct I225/I226 initialization sequence for reliable link and DMA operation.

#### Scenario: Initialization order corrected
- **WHEN** igcd initializes
- **THEN** it performs: (1) global reset, (2) disable interrupts, (3) read MAC, (4) configure RAL0/RAH0, (5) clear MTA, (6) set packet buffer sizes, (7) init RX ring and enable RXDCTL, (8) enable RCTL, (9) init TX ring and enable TXDCTL, (10) enable TCTL, (11) enable interrupts, (12) set CTRL.SLU
- **AND** CTRL.SLU is set AFTER RX/TX rings are configured (not before)

### Requirement: RX descriptor struct correctness
The advanced RX descriptor writeback struct must match the I225/I226 hardware layout exactly.

#### Scenario: Writeback field offsets verified
- **GIVEN** the I225/I226 advanced RX descriptor writeback format is: [rss_hash:u32, pkt_info:u32, status_error:u32, length:u16, vlan:u16]
- **WHEN** hardware writes back an RX descriptor
- **THEN** `desc.wb.status_error` reads the correct DD/EOP bits and `desc.wb.length` reads the correct packet length

### Requirement: Interrupt acknowledgment
The igcd driver must properly acknowledge interrupts to allow subsequent interrupts to fire.

#### Scenario: ICR read-to-clear
- **WHEN** the driver reads ICR at 0x01500
- **THEN** all cause bits are cleared by the read
- **AND** the driver does not need to write ICR to acknowledge (I225/I226 uses read-to-clear, not write-1-to-clear)

### Requirement: RX path packet delivery
The igcd driver must successfully receive Ethernet frames and deliver them to scheme clients.

#### Scenario: ARP reply received
- **WHEN** the network switch sends an ARP reply to the I226-V's MAC address
- **THEN** the NIC DMAs the frame into an RX descriptor buffer, sets DD, and the driver's `read_packet()` returns the frame data

#### Scenario: Ping reply received
- **WHEN** a remote host sends an ICMP echo reply
- **THEN** smolnetd receives the frame via `read_packet()`, processes it, and reports the ping round-trip time
