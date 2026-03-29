## ADDED Requirements

### Requirement: Match opcode executes without panic
The AML interpreter SHALL handle the `Match` opcode (0x89) without panicking. The interpreter SHALL parse the interleaved TermArg and raw byte arguments, perform the package search, and return the matching index or ONES (0xFFFFFFFFFFFFFFFF) if no match is found.

#### Scenario: Match opcode in DSDT table
- **WHEN** acpid loads a DSDT table containing a Match opcode
- **THEN** the AML interpreter parses all six arguments (SearchPkg, MatchOp1, Operand1, MatchOp2, Operand2, StartIndex), executes the search, and continues table loading without error

#### Scenario: Match with no matching element
- **WHEN** the Match opcode executes and no element in the SearchPkg satisfies both match conditions
- **THEN** the interpreter returns ONES (0xFFFFFFFFFFFFFFFF) as the result

#### Scenario: Match with valid match
- **WHEN** the Match opcode executes and element at index N satisfies both MatchOp1/Operand1 and MatchOp2/Operand2 conditions starting from StartIndex
- **THEN** the interpreter returns N as the result

### Requirement: All six match operators supported
The Match opcode implementation SHALL support all six ACPI match operators: MTR (always true), MEQ (equal), MLE (less or equal), MLT (less than), MGE (greater or equal), MGT (greater than).

#### Scenario: MTR operator matches any value
- **WHEN** a Match operation uses MTR (0) as a match operator
- **THEN** the condition is satisfied for any operand value

#### Scenario: MEQ operator matches equal values
- **WHEN** a Match operation uses MEQ (1) with Operand value 42
- **THEN** only package elements equal to 42 satisfy the condition

### Requirement: acpid completes DSDT/SSDT loading on Intel N100
The acpid daemon SHALL successfully load all DSDT and SSDT tables from the Intel N100's ACPI firmware and register the `acpi:` scheme with a populated namespace.

#### Scenario: acpid provides MCFG to pcid
- **WHEN** acpid starts on the LattePanda Mu and loads ACPI tables
- **THEN** pcid accesses PCIe configuration space via MCFG (not PCI 3.0 fallback) and reads non-zero BAR addresses for NVMe, Ethernet, and xHCI controllers

### Requirement: PCI drivers load with valid BARs
When acpid provides MCFG tables, pcid SHALL map PCI BARs correctly, and pcid-spawner SHALL start all configured drivers (nvmed, rtl8168d, xhcid) without BAR mapping errors.

#### Scenario: RTL8168 Ethernet driver starts
- **WHEN** pcid reads the RTL8168 NIC BAR via MCFG and pcid-spawner starts rtl8168d
- **THEN** rtl8168d registers the `network:` scheme and smolnetd acquires a DHCP lease

#### Scenario: xHCI USB controller starts
- **WHEN** pcid reads the xHCI controller BAR via MCFG and pcid-spawner starts xhcid
- **THEN** xhcid enumerates USB devices and spawns usbhidd for HID keyboards without USB Transaction Errors
