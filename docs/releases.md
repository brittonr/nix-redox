# Releases

Tagged releases publish bootable disk images for the graphical and minimal
profiles. The release workflow runs on any `v*` tag.

## Cutting a release

```bash
git tag -a v0.2.0-alpha -m "nix-redox v0.2.0-alpha"
git push origin v0.2.0-alpha
```

The **Release** workflow then:

1. builds `.#redox-graphical` and `.#redox-minimal`;
2. copies each `redox.img` into a release asset;
3. writes `SHA256SUMS`;
4. creates the GitHub release if the tag does not already have one;
5. uploads all three assets.

The workflow marks newly created releases as prereleases. Edit the release to
add curated notes from [`CHANGELOG.md`](../CHANGELOG.md) if the generated notes
are not sufficient.

## Verifying assets

```bash
sha256sum -c SHA256SUMS
qemu-system-x86_64 \
  -M pc -cpu host -m 2048 -smp 4 -enable-kvm \
  -bios /path/to/OVMF.fd \
  -drive file=redox-graphical.img,format=raw,if=virtio \
  -display gtk
```

The images are the same GPT/UEFI disk images produced by `nix build`. The
graphical image boots Orbital; the minimal image is intended for serial-console
and development use.

## Alpha caveat

Bare-metal installation is experimental. The images are safe to boot in a VM;
writing them to physical media requires the same care as any raw disk image.
