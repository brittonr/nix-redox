# End-to-end demo

`record-e2e.py` boots a graphical Redox image, logs in through Orbital, runs
`tree --version`, `snix system info`, and `snix system services`, captures the
VGA surface through the QEMU monitor, and encodes an MP4 with intro/outro cards.

It is intentionally non-interactive. QEMU keyboard and mouse input is sent
through the HMP monitor; no X/Wayland session is required.

## Record

```bash
nix build .#redox-graphical -o result-image
nix build .#bootloader -o result-boot

python3 demo/record-e2e.py \
  --image result-image/redox.img \
  --bootloader result-boot/boot/EFI/BOOT/BOOTX64.EFI \
  --ovmf /path/to/OVMF.fd \
  --output docs/assets/demo/nix-redox-e2e.mp4
```

The published v0.1.2 image also works:

```bash
gh release download v0.1.2-alpha --pattern redox-graphical.img --repo brittonr/nix-redox
python3 demo/record-e2e.py \
  --image redox-graphical.img \
  --bootloader /path/to/BOOTX64.EFI \
  --ovmf /path/to/OVMF.fd \
  --output docs/assets/demo/nix-redox-e2e.mp4
```

## What it shows

1. UEFI boot and Orbital login.
2. Login as `user` / `redox`.
3. `tree --version`.
4. `snix system info` and `snix system services` inside the guest.

The script requires `ffmpeg`, ImageMagick, a font discoverable by `fc-match`,
and KVM. Frames are captured at roughly 4-5 fps and retimed from their actual
timestamps.
