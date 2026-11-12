# End-to-end asciinema demo

`record-e2e.py` boots a Redox image in QEMU, logs in over the serial console,
runs `tree --version`, `snix eval`, a `snix build` of a fresh package, and
`snix system info`/`snix system services`, and records the guest terminal with
`asciinema`. The cast is rendered to MP4 with `asciinema-agg` and ffmpeg.

It is intentionally non-interactive. QEMU serial input and output go through a
Unix socket, so no graphical session or X server is required.

## Record

The recorder needs `asciinema` and `asciinema-agg` on `PATH`:

```bash
nix build .#redox-graphical -o result-image
nix build .#bootloader -o result-boot

nix shell nixpkgs#asciinema nixpkgs#asciinema-agg -c \
  python3 demo/record-e2e.py \
    --image result-image/redox.img \
    --bootloader result-boot/boot/EFI/BOOT/BOOTX64.EFI \
    --ovmf /path/to/OVMF.fd \
    --output docs/assets/demo/nix-redox-e2e.mp4
```

The published v0.1.2 image also works:

```bash
gh release download v0.1.2-alpha --pattern redox-graphical.img --repo brittonr/nix-redox
nix shell nixpkgs#asciinema nixpkgs#asciinema-agg -c \
  python3 demo/record-e2e.py \
    --image redox-graphical.img \
    --bootloader /path/to/BOOTX64.EFI \
    --ovmf /path/to/OVMF.fd \
    --output docs/assets/demo/nix-redox-e2e.mp4
```

The script writes three artifacts beside `--output`:

- `nix-redox-e2e.cast` — the asciinema recording (source of truth)
- `nix-redox-e2e.mp4` — the rendered video
- `nix-redox-e2e-poster.png` — a still for the site

Play the cast locally with:

```bash
asciinema play docs/assets/demo/nix-redox-e2e.cast
```

## Self-build proof video

`render-self-build.py` turns a completed `native-rebuild-test` capture into a
short evidence replay. It reads the three guest serial logs and summary, then
emits an asciicast and renders it with `asciinema-agg` and ffmpeg.

```bash
nix shell nixpkgs#asciinema-agg -c \
  python3 demo/render-self-build.py \
    --capture /var/tmp/redox-self-hosting-captures/<run-id>-native-rebuild-test \
    --output docs/assets/demo/nix-redox-self-build.mp4
```

The video copies selected guest output; the timeline is compressed and the
original run ID is displayed. It is an evidence replay, not a live run.

## What it shows

1. UEFI boot and the Redox serial login.
2. Login as `root` / `redox`; the demo builds into the read-only `/nix/store`
  as root.
3. `tree --version`.
4. `snix eval --expr "1 + 1"`.
5. `snix build` of a fresh package, including the resulting store path.
6. `cat /nix/store/*-nix-demo` to show the built package contents.
7. `snix system info` and `snix system services` inside the guest.

QEMU keyboard input is sent to the guest's serial console. The bootloader's
default entry is selected with a carriage return; `LF` is not an Enter key on
this path. The recorder needs `ffmpeg` for MP4 rendering and KVM for the VM.
