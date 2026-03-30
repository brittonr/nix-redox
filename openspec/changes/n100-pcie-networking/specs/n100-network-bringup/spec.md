## ADDED Requirements

### REQ-N100-NIC-DETECT

On the Intel N100 LattePanda Mu, pcid SHALL discover the RTL8168
Gigabit Ethernet controller (behind a PCIe bridge) and spawn rtl8168d.

### REQ-N100-NVME-DETECT

On the Intel N100 LattePanda Mu, pcid SHALL discover the NVMe
controller (behind a PCIe bridge) and spawn nvmed. The `disk:` scheme
SHALL be registered.

### REQ-N100-PCI-IDS

The pcid TOML configuration SHALL include the exact PCI vendor:device
IDs for the N100 Carrier Lite's RTL8168 NIC and the installed NVMe
SSD. IDs captured via `lspci -nn` on Linux.

### REQ-SMOLNETD-STARTUP

smolnetd SHALL start successfully and register `net:`, `ip:`, `tcp:`,
`udp:` schemes when a network interface driver is available. If no
NIC driver is present, smolnetd SHALL either wait or exit with a
clear error message — not crash silently.

### REQ-NETWORK-DHCP

When rtl8168d registers a network interface, dhcpd SHALL acquire a
DHCP lease. `ping` to an external IP SHALL succeed.

### REQ-INIT-ORDERING

The init script ordering SHALL ensure NIC drivers start before
smolnetd, and smolnetd starts before dhcpd. If smolnetd depends on
a NIC scheme being available, the init scripts SHALL use `notify`
(blocking wait) for the NIC driver before starting smolnetd.
