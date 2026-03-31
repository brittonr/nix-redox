## MODIFIED Requirements

### Requirement: Automatic network configuration on boot
The system must automatically configure networking when a PCI network driver registers a scheme, without manual shell commands.

#### Scenario: DHCP on bare metal boot
- **WHEN** the system boots with `networkDrivers = ["igcd"]` and `mode = "auto"`
- **THEN** smolnetd discovers the igcd network scheme, dhcpd-quiet runs `netcfg-setup dhcpd`, DHCP obtains a lease, and the IP/gateway/DNS are configured automatically

#### Scenario: netcfg-setup auto from shell
- **WHEN** a user runs `/bin/netcfg-setup auto` after boot
- **THEN** netcfg-setup discovers the network interface, runs DHCP, and configures IP via the netcfg scheme's `eth0` interface

#### Scenario: netcfg-setup static-auto from shell
- **WHEN** a user runs `/bin/netcfg-setup static-auto --address 192.168.1.100/24 --gateway 192.168.1.1`
- **THEN** netcfg-setup discovers the network interface and configures the IP and default route via the netcfg scheme

#### Scenario: netcfg-setup dhcpd from shell
- **WHEN** a user runs `/bin/netcfg-setup dhcpd`
- **THEN** netcfg-setup discovers the network interface, sends DHCP Discover via the network scheme, receives DHCP Offer/Ack, and configures IP via the netcfg scheme

#### Scenario: ping works after auto-config
- **WHEN** DHCP or static-auto configuration completes
- **THEN** `ping <gateway>` succeeds with 0% packet loss
