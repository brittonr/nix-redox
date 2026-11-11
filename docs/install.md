# Installing Redox

Redox is distributed as a complete GPT/UEFI disk image. There is no partition
wizard yet: the image contains the EFI system partition and RedoxFS root.

## VM

The supported alpha path is a VM:

```bash
nix run github:brittonr/nix-redox
```

Headless:

```bash
nix run github:brittonr/nix-redox#headless
```

Log in as `user` with password `redox`; `root` uses the same password.

## USB or bare metal (experimental)

1. Download an image and its checksums from a
   [release](https://github.com/brittonr/nix-redox/releases), or build one:

   ```bash
   nix run .#redox-rebuild -- export graphical --out redox-graphical.img
   ```

2. Verify the image:

   ```bash
   sha256sum -c redox-graphical.img.sha256
   ```

3. Write it to a USB device. **Double-check the device path**; this destroys
   the target. The installer validates the image checksum, refuses mounted or
   undersized devices, and verifies the read-back:

   ```bash
   nix run .#redox-install -- list
   sudo nix run .#redox-install -- write \
     --image redox-graphical.img --device /dev/sdX
   ```

   It prompts for `WRITE` unless `--yes` is passed. `--dry-run` performs all
   validation without writing. A traditional `dd` also works:

   ```bash
   sudo dd if=redox-graphical.img of=/dev/sdX bs=4M status=progress oflag=sync
   sync
   ```

4. Boot the target in UEFI mode. Secure Boot must be disabled. The graphical
   image boots Orbital; the minimal image is intended for serial console and
   development use.

Bare-metal support is experimental. Validated hardware notes live in
[`bare-metal-lattepanda-mu.md`](bare-metal-lattepanda-mu.md) and the alpha
limitations in [`alpha-release.md`](alpha-release.md). Firmware, GPU, Wi-Fi,
and some NIC paths remain board-specific.

## Updates

Inside a booted system:

```bash
snix system rebuild
snix system switch --rollback
snix system generations
```

On the host, `redox-rebuild` tracks configuration generations and can export a
fresh image. Replacing a physical disk image is not an in-place upgrade; keep
the previous image until the new one boots and the guest configuration is
verified.

## Change the default credentials

The image ships `user`/`redox` and `root`/`redox` for local development. Change
them before exposing any service to a network.
