## 1. Fix netcfg-setup interface discovery

- [x] 1.1 In `src/netcfg-setup/src/main.rs`, modify `discover_first_interface()` to fall back to `"eth0"` when `fs::read_dir("/scheme/netcfg/ifaces")` fails — smolnetd's netcfg scheme doesn't support directory listing, so read_dir always returns Err. The fallback should check if `/scheme/netcfg/ifaces/eth0/mac` is readable before accepting `"eth0"`.
- [x] 1.2 Modify `wait_for_any_interface()` to also try the `"eth0"` fallback on each poll attempt — the interface may not be available immediately at boot (smolnetd starts after igcd)
- [x] 1.3 Verify `netcfg-setup auto` works from the shell on the GMKtec — should discover `eth0`, run DHCP, configure IP
- [x] 1.4 Verify `netcfg-setup dhcpd` works from the shell — should discover `eth0`, send DHCP Discover, get lease
- [x] 1.5 Verify `netcfg-setup static-auto --address 192.168.1.146/24 --gateway 192.168.1.1` works from the shell

## 2. Verify boot-time auto-configuration

- [ ] 2.1 Build disk image with fixed netcfg-setup, boot on GMKtec
- [ ] 2.2 Verify dhcpd.log exists at `/var/log/dhcpd.log` after boot — confirms dhcpd-quiet ran
- [ ] 2.3 Verify IP is configured: `cat /scheme/netcfg/ifaces/eth0/addr/list` shows DHCP-assigned address
- [ ] 2.4 Verify ping works immediately after login (no manual config): `ping -c 4 192.168.1.1`

## 3. Test TCP and cleanup

- [ ] 3.1 Test HTTP fetch: `curl http://<some-host>/` or fetch a URL via redox-curl
- [ ] 3.2 Mark igc-network-driver tasks 8.4 and 8.5 as complete
- [ ] 3.3 Update napkin.md with netcfg-setup discovery fix and smolnetd `eth0` naming convention
