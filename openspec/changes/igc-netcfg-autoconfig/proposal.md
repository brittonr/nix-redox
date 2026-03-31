## Why

The igcd driver works — ping succeeds on bare metal with manual IP configuration. But networking doesn't auto-configure on boot because `netcfg-setup` and smolnetd disagree on interface naming. smolnetd hardcodes the interface as `eth0` in its netcfg scheme tree, while `netcfg-setup` auto-discovers by scanning `/scheme/` for `network.*` entries and uses PCI-path names (e.g., `pci-0000-03-00.0_igc`). The mismatch means `netcfg-setup dhcpd` reports "no network interface found" and DHCP never runs.

## What Changes

- Fix netcfg-setup to configure smolnetd via the `eth0` interface name in the netcfg scheme, not the PCI-path name
- OR fix smolnetd to register the actual PCI-path interface name in the netcfg scheme instead of hardcoded `eth0`
- Ensure `dhcpd-quiet` (the boot-time DHCP service) successfully obtains a lease on the GMKtec I226-V
- Verify end-to-end: boot → DHCP → ping → curl all work without manual intervention

## Capabilities

### New Capabilities

### Modified Capabilities
- `igc-driver`: Auto-configured networking on boot — DHCP obtains IP, routes configured, ping works without manual shell commands

## Impact

- **netcfg-setup**: `nix/pkgs/userspace/netcfg-setup.nix` — fix interface name resolution to match smolnetd's `eth0` convention, or pass the scheme name through
- **smolnetd (netstack)**: `netstack/src/scheme/netcfg/mod.rs` — the `mk_root_node` function hardcodes `"eth0"` in the ifaces tree. Could use the actual adapter name from `get_network_adapter()`
- **dhcpd-quiet**: generated script in `generated-files.nix` — runs `/bin/netcfg-setup dhcpd`, needs the discovery fix to work
- **Test hardware**: GMKtec NucBoxG3 Plus (I226-V), verified working with manual config
- **Also affects**: any bare-metal Redox system using PCI network drivers with the "auto" networking mode
