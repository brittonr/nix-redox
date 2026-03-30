## 1. Linux PCI Audit

- [ ] 1.1 Boot a Linux live USB on the LattePanda Mu
- [ ] 1.2 Run `lspci -nn` and capture full PCI topology (all buses, bridges, device IDs)
- [ ] 1.3 Run `lspci -tv` to capture the tree view showing bridge→device hierarchy
- [ ] 1.4 Identify the RTL8168 vendor:device ID (e.g., 10ec:8168) and its bus address
- [ ] 1.5 Identify the NVMe controller vendor:device ID and its bus address
- [ ] 1.6 Run `cat /proc/ioports | grep serial` and `dmesg | grep -i uart` to document UART type
- [ ] 1.7 Save all output to `docs/n100-pci-topology.txt`

## 2. PCIe Bridge Enumeration in pcid

- [ ] 2.1 Read pcid source to understand current bus 0 scanning logic (`redox-os--base/drivers/pci/pcid/`)
- [ ] 2.2 Identify where bus scanning happens and how device addresses are constructed
- [ ] 2.3 Write a patch that, after bus 0 scan, iterates discovered devices looking for class=0x06 subclass=0x04 (PCI-to-PCI bridge)
- [ ] 2.4 For each bridge, read Secondary Bus Number (config offset 0x19) and Subordinate Bus Number (offset 0x1A)
- [ ] 2.5 Scan all device/function slots on the secondary bus using existing config space read logic
- [ ] 2.6 Add recursion for bridges on subordinate buses (depth limit of 8)
- [ ] 2.7 Test in QEMU with a multi-bus PCI topology (add `-device pcie-root-port` + device behind it)
- [ ] 2.8 Create `patch-pcid-pcie-bridge-enum.py` and integrate into `base.nix`

## 3. PCI Device ID Configuration

- [ ] 3.1 Add the N100's RTL8168 vendor:device ID to pcid's TOML driver config
- [ ] 3.2 Add the NVMe controller's vendor:device ID (or use class-based matching if pcid supports it)
- [ ] 3.3 Verify pcid-spawner launches rtl8168d and nvmed on subordinate bus devices
- [ ] 3.4 Test on N100 hardware — confirm both drivers start (check serial log)

## 4. smolnetd Startup Fix

- [ ] 4.1 Capture smolnetd's full error output via serial log during boot
- [ ] 4.2 Read smolnetd source to understand what it needs at startup (scheme dependencies, NIC availability)
- [ ] 4.3 Determine if smolnetd exits because no NIC scheme exists, or for another reason
- [ ] 4.4 Fix the root cause (init ordering, missing scheme wait, or code bug)
- [ ] 4.5 Verify smolnetd registers `net:`, `ip:`, `tcp:`, `udp:` schemes after fix

## 5. Network Validation

- [ ] 5.1 Boot N100 with PCIe bridge enumeration + smolnetd fix
- [ ] 5.2 Verify `ls /scheme/net` shows a network interface
- [ ] 5.3 Verify dhcpd acquires a DHCP lease (`cat /scheme/netcfg` or similar)
- [ ] 5.4 Test `ping` to an external IP (e.g., gateway or 1.1.1.1)
- [ ] 5.5 Verify NVMe: `ls /scheme/disk/` shows the SSD

## 6. Documentation

- [ ] 6.1 Update `docs/bare-metal-lattepanda-mu.md` with PCI topology, networking status, NVMe status
- [ ] 6.2 Add `docs/n100-pci-topology.txt` with Linux lspci output
- [ ] 6.3 Update `examples/lattepanda-mu/configuration.nix` if any config changes needed
