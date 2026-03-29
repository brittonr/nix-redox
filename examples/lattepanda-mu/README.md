# LattePanda Mu — Bare Metal Redox OS

Boots Redox OS on the LattePanda Mu (Intel N100, 8GB RAM) with the Carrier Lite board.

## Hardware

- **Board**: LattePanda Mu (DFR1146) + Carrier Lite (DFR1142)
- **Boot media**: USB flash drive or M.2 2230 NVMe SSD (M-Key slot)
- **Ethernet**: RTL8111 GbE (rtl8168d)
- **Display**: HDMI 2.0 via UEFI GOP framebuffer (vesad)
- **USB**: xHCI (keyboard, mouse, storage)
- **Not supported**: eMMC (no SDHCI driver), WiFi (no driver)

## Build

```bash
nix build
```

## Flash to USB

```bash
dd if=result/redox.img of=/dev/sdX bs=4M status=progress
```

## BIOS Setup

1. Enter BIOS (Del at power-on)
2. Disable Secure Boot
3. Set boot order: USB first, then NVMe

## Boot

1. Plug USB drive into Carrier Lite USB 3.2 port
2. Connect HDMI monitor + USB keyboard
3. Power on
4. Optional: connect USB-UART cable to SIO_UART header (115200 8N1) for serial debug

## Test in QEMU first

```bash
nix run          # graphical (QEMU + GTK)
nix run .#headless  # serial console only
```
