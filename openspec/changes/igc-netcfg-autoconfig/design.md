## Context

smolnetd discovers the network adapter at startup by scanning `/scheme/` for entries starting with `network`. It opens the first match (e.g., `network.pci-0000-03-00.0_igc`) and uses it for packet I/O. This works — RX and TX are functional.

However, smolnetd's netcfg scheme tree hardcodes the interface as `ifaces/eth0/...` regardless of the actual adapter name. The `netcfg-setup` tool auto-discovers by scanning `/scheme/` for `network.*` entries, extracts the PCI-path name (e.g., `pci-0000-03-00.0_igc`), then tries to configure via `/scheme/netcfg/<pci-path-name>`. Since netcfg only has `eth0`, the lookup fails.

The `dhcpd-quiet` init service runs `netcfg-setup dhcpd` which hits the same discovery failure. DHCP never runs, so bare metal boots have no IP.

Manual workaround (verified working):
```
echo "192.168.1.100/24" > /scheme/netcfg/ifaces/eth0/addr/set
echo "default via 192.168.1.1" > /scheme/netcfg/route/add
```

## Goals / Non-Goals

**Goals:**
- DHCP works automatically on bare metal boot with igcd
- `netcfg-setup auto` and `netcfg-setup dhcpd` work from the shell
- No manual IP configuration required after boot
- Fix works for ALL PCI network drivers (e1000d, rtl8168d, ixgbed), not just igcd

**Non-Goals:**
- Multi-interface support (smolnetd currently only handles one adapter)
- Interface renaming or udev-style naming
- IPv6 auto-configuration

## Decisions

**1. Fix netcfg-setup to use `eth0` for netcfg scheme access**

The simplest fix with the broadest compatibility. `netcfg-setup` already discovers the network scheme name from `/scheme/`. It should use this name for I/O (reading MAC, sending packets) but use `eth0` for netcfg configuration paths, since that's what smolnetd registers.

Specifically, `netcfg-setup` commands should:
- Discover: scan `/scheme/` for `network.*` → get the scheme name
- Configure IP: write to `/scheme/netcfg/ifaces/eth0/addr/set` (not `/scheme/netcfg/<pci-name>/...`)
- Configure route: write to `/scheme/netcfg/route/add`
- DHCP: send DHCP packets via the discovered scheme, configure via `eth0` netcfg paths

**2. Keep smolnetd's `eth0` naming for now**

Changing smolnetd to use PCI-path names would require dynamic netcfg tree construction, which is a larger refactor. The `eth0` convention is standard and works for single-interface systems.

**3. Verify the full boot path**

After fixing netcfg-setup, verify the init service chain:
`init → smolnetd (discovers igcd) → dhcpd-quiet → netcfg-setup dhcpd → DHCP lease → IP configured`

## Risks / Trade-offs

- **Single-interface assumption**: smolnetd only handles one adapter. The `eth0` name works for this case. Multi-interface would need smolnetd changes (out of scope).
- **netcfg-setup is a Rust binary**: changes require rebuilding the netcfg-setup package and updating the build plan.
- **Boot ordering**: smolnetd must start AFTER igcd registers its scheme. Currently smolnetd is a rootfs service (starts after rootfs mount) and igcd starts during initfs (pcid-spawner phase 40). This ordering works because rootfs mount (phase 50) happens after pcid-spawner.
