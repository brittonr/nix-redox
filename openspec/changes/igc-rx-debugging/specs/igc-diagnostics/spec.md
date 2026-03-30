## ADDED Requirements

### Requirement: Debug logging at initialization
The igcd driver must log hardware state at each initialization phase when debug level is enabled.

#### Scenario: Reset diagnostics
- **WHEN** igcd performs a global reset
- **THEN** it logs CTRL and STATUS register values before and after reset at debug level

#### Scenario: Link status after init
- **WHEN** igcd completes PHY initialization
- **THEN** it logs the STATUS register value including LU bit and speed field at info level

#### Scenario: Descriptor ring diagnostics
- **WHEN** igcd sets up RX and TX descriptor rings
- **THEN** it logs ring physical addresses, SRRCTL value, RDBAL/RDBAH, TDBAL/TDBAH, and descriptor count at debug level

### Requirement: IRQ diagnostic logging
The igcd driver must log interrupt cause information when debug level is enabled.

#### Scenario: IRQ cause logging
- **WHEN** the driver handles an interrupt and ICR is non-zero
- **THEN** it logs the ICR value with decoded cause bits (RXT0, TXDW, LSC, RXDMT0) at debug level

#### Scenario: Periodic heartbeat
- **WHEN** the driver has handled 1000 interrupts since last heartbeat
- **THEN** it logs STATUS, RDH0, RDT0, TDH0, TDT0, and interrupt count at info level

### Requirement: RX/TX path diagnostic logging
The igcd driver must log packet-level diagnostics when trace level is enabled.

#### Scenario: RX descriptor check
- **WHEN** `available_for_read()` is called at trace level
- **THEN** it logs the current RX descriptor index, DD bit state, and status_error field

#### Scenario: Packet received
- **WHEN** `read_packet()` successfully reads a packet
- **THEN** it logs the packet length and first 14 bytes (Ethernet header) at debug level

#### Scenario: Packet transmitted
- **WHEN** `write_packet()` queues a packet for transmission
- **THEN** it logs the packet length, TX descriptor index, and TDT value at debug level

### Requirement: On-demand register dump
The igcd driver must support a diagnostic interface for dumping register state from the shell.

#### Scenario: Register dump via scheme
- **WHEN** a process opens the network scheme's "diag" path and writes "status"
- **THEN** igcd logs CTRL, STATUS, ICR, IMS, RCTL, TCTL, RDBAL0, RDBAH0, RDH0, RDT0, TDBAL0, TDBAH0, TDH0, TDT0, RAL0, RAH0, RXPBS, TXPBS at info level

### Requirement: Log level control via bootloader env
The igcd driver must respect the driver log level override from the bootloader environment.

#### Scenario: Debug level override
- **WHEN** the bootloader environment contains `DRIVER_PCI_LOG_LEVEL=Debug`
- **THEN** igcd's stderr output includes debug-level messages
