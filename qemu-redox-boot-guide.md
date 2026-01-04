# QEMU RedoxOS UEFI Boot Configuration Guide

This guide documents various QEMU configurations that successfully boot RedoxOS UEFI disk images, based on comprehensive testing.

## Key Findings

### Critical Requirement: Direct Kernel Boot

**The most important finding is that RedoxOS UEFI images require direct kernel boot** (`-kernel` option) to work properly. Standard UEFI disk booting fails because the firmware cannot locate the EFI boot entries on the disk.

### Working Configuration Pattern

```bash
qemu-system-x86_64 \
  -m 2048 \
  -smp 2 \
  -enable-kvm \
  -kernel /path/to/BOOTX64.EFI \        # CRITICAL: Direct boot required
  -M [pc|q35] \                         # Both machine types work
  -bios /path/to/OVMF.fd \             # Standard OVMF firmware
  -drive file=redox.img,format=raw,if=[interface] \  # Various interfaces work
  -serial stdio \
  -display [none|gtk] \
  -device isa-debug-exit               # For automated testing
```

## Tested Drive Interface Types

All of the following drive interfaces work successfully with RedoxOS when using direct kernel boot:

### 1. IDE Interface (Legacy, Default)
```bash
-drive file=redox.img,format=raw,if=ide
```
- **Status**: ✅ **Working**
- **Machine Types**: pc, q35
- **Notes**: Default configuration used in the current flake.nix
- **Detection Path**: `Acpi(PNP0A03,0x0)/Pci(0x1,0x1)/Messaging Atapi`

### 2. AHCI/SATA Interface
```bash
-M q35 \
-drive file=redox.img,format=raw,if=none,id=disk0 \
-device ahci,id=ahci0 \
-device ide-hd,drive=disk0,bus=ahci0.0
```
- **Status**: ✅ **Working**
- **Machine Types**: q35 (preferred), pc (with modifications)
- **Notes**: Modern SATA interface, more realistic hardware simulation
- **Detection Path**: `Acpi(PNP0A03,0x0)/Pci(0x3,0x0)/Sata`

### 3. VirtIO Block Device
```bash
-drive file=redox.img,format=raw,if=none,id=disk0 \
-device virtio-blk-pci,drive=disk0
```
- **Status**: ✅ **Working**
- **Machine Types**: pc, q35
- **Notes**: Best performance, paravirtualized storage
- **Detection Path**: `Acpi(PNP0A03,0x0)/Pci(0x3,0x0)`

### 4. NVMe Interface
```bash
-drive file=redox.img,format=raw,if=none,id=disk0 \
-device nvme,drive=disk0
```
- **Status**: 🔧 **Configuration Issues**
- **Notes**: Modern NVMe storage, but has device conflicts in testing
- **Recommendation**: Use VirtIO for similar performance benefits

### 5. SCSI Interface
```bash
-drive file=redox.img,format=raw,if=none,id=disk0 \
-device virtio-scsi-pci \
-device scsi-hd,drive=disk0
```
- **Status**: 🧪 **Needs Further Testing**
- **Notes**: SCSI emulation, useful for specific testing scenarios

## Machine Type Comparison

### PC Machine Type (-M pc)
```bash
-M pc
```
- **Status**: ✅ **Working**
- **Pros**: Default, legacy compatibility, smaller footprint
- **Cons**: Older chipset simulation
- **Use Case**: Default choice, legacy system simulation

### Q35 Machine Type (-M q35)
```bash
-M q35
```
- **Status**: ✅ **Working**
- **Pros**: Modern PCIe chipset, better device support
- **Cons**: Slightly more resource usage
- **Use Case**: Modern system simulation, AHCI/PCIe devices

**Recommendation**: Both work well. Use `pc` for simplicity, `q35` for modern hardware simulation.

## OVMF Firmware Options

### OVMF.fd (All-in-One)
```bash
-bios /path/to/OVMF.fd
```
- **Status**: ✅ **Working** (Current flake.nix standard)
- **Pros**: Simple, single file
- **Cons**: No persistent UEFI variables

### OVMF_CODE.fd + OVMF_VARS.fd (Split Firmware)
```bash
-drive if=pflash,format=raw,readonly=on,file=/path/to/OVMF_CODE.fd \
-drive if=pflash,format=raw,file=/path/to/OVMF_VARS.fd
```
- **Status**: 🔧 **Needs NVRAM Setup**
- **Pros**: Persistent UEFI variables, more realistic
- **Cons**: More complex configuration
- **Use Case**: When UEFI variable persistence is needed

## Boot Process Analysis

### Successful Boot Sequence
1. **UEFI Firmware Start**: OVMF initializes
2. **Direct Kernel Load**: `-kernel` option bypasses normal UEFI boot
3. **Bootloader Start**: RedoxOS UEFI bootloader initializes
   ```
   Redox OS Bootloader 1.0.0 on x86_64/UEFI
   Hardware descriptor: Acpi(7f538000, 24)
   ```
4. **Storage Detection**: Bootloader scans for RedoxFS
   ```
   Looking for RedoxFS:
   - [Device Path]
   - [Partition 1: EFI System]
   - [Partition 2: Linux filesystem]
   RedoxFS e9b4115c-6faa-4880-bae3-20b13bb6ed15: 222 MiB
   ```
5. **Display Setup**: Resolution selection menu appears
   ```
   Output 0, best resolution: 1280x800
   Arrow keys and enter select mode
   ```

### Failed Boot Analysis (Direct Disk Boot)
When attempting to boot directly from disk without `-kernel` option:
```
BdsDxe: failed to load Boot0002 "UEFI QEMU HARDDISK" from [DevicePath]: Not Found
BdsDxe: No bootable option or device was found.
```

**Root Cause**: UEFI firmware cannot locate proper boot entries in the ESP. The RedoxOS image expects direct kernel loading rather than standard UEFI boot manager operation.

## Recommended Configurations

### Development/Testing (Current Flake Default)
```bash
qemu-system-x86_64 \
  -M pc \
  -cpu host \
  -m 2048 \
  -smp 4 \
  -enable-kvm \
  -bios /nix/store/.../OVMF.fd \
  -kernel /path/to/BOOTX64.EFI \
  -drive file=redox.img,format=raw,if=ide \
  -serial stdio \
  -display none
```

### High Performance
```bash
qemu-system-x86_64 \
  -M q35 \
  -cpu host \
  -m 2048 \
  -smp 4 \
  -enable-kvm \
  -bios /nix/store/.../OVMF.fd \
  -kernel /path/to/BOOTX64.EFI \
  -drive file=redox.img,format=raw,if=none,id=disk0 \
  -device virtio-blk-pci,drive=disk0 \
  -serial stdio \
  -display gtk
```

### Modern Hardware Simulation
```bash
qemu-system-x86_64 \
  -M q35 \
  -cpu host \
  -m 2048 \
  -smp 4 \
  -enable-kvm \
  -bios /nix/store/.../OVMF.fd \
  -kernel /path/to/BOOTX64.EFI \
  -drive file=redox.img,format=raw,if=none,id=disk0 \
  -device ahci,id=ahci0 \
  -device ide-hd,drive=disk0,bus=ahci0.0 \
  -serial stdio \
  -display gtk
```

## Common Issues and Solutions

### Issue: "No bootable option or device was found"
**Solution**: Always use `-kernel /path/to/BOOTX64.EFI` for RedoxOS images.

### Issue: "drive with bus=0, unit=0 (index=0) exists"
**Solution**: Avoid mixing legacy drive options (-hda) with modern drive configurations when using -kernel.

### Issue: Permission denied accessing OVMF_VARS.fd
**Solution**: Copy OVMF_VARS.fd to a writable location and set proper permissions:
```bash
cp /nix/store/.../OVMF_VARS.fd /tmp/OVMF_VARS.fd
chmod 644 /tmp/OVMF_VARS.fd
```

### Issue: Resolution selection timeout
**Solution**: Normal behavior - RedoxOS shows resolution menu, will auto-select after timeout or manual selection.

## Performance Notes

- **KVM**: Always use `-enable-kvm` when available for hardware acceleration
- **VirtIO**: Provides best I/O performance for storage and networking
- **Memory**: 2GB+ recommended for RedoxOS, 1GB minimum
- **CPU**: Host CPU passthrough recommended with `-cpu host`

## Files and Paths

- **Disk Image**: Usually `/nix/store/.../redox.img` (256 MB)
- **Bootloader**: `/nix/store/.../boot/EFI/BOOT/BOOTX64.EFI` (192 KB)
- **OVMF Firmware**: `/nix/store/.../FV/OVMF.fd` (4 MB)
- **ESP Structure**:
  - Partition 1: EFI System Partition (32 MB FAT32)
  - Partition 2: RedoxFS root filesystem (222 MB)

This guide should enable successful QEMU configuration for RedoxOS UEFI images across various hardware simulation scenarios.
