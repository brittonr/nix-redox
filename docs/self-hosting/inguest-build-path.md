# In-guest build path

This records the decision for [#43](https://github.com/brittonr/nix-redox/issues/43):
nix-redox keeps one guest-native build graph and feeds it from pinned sources.
The host produces the seed image; later builds run in the guest.

## Rebuild and reboot on Redox

Start with the x86_64 UEFI `redox-native-seed` disk image. An already-built
image can be written to boot media without NixOS; to produce the initial
image from this checkout, run `nix build .#redox-native-seed` on a Linux Nix
builder. The seed includes Snix, the toolchain, the native source bundle,
and a `systemSource` in `/etc/redox-system/configuration.nix`.

On Redox, edit `/etc/redox-system/configuration.nix` and run as root:

```sh
snix system rebuild --dry-run
snix system rebuild
snix system generations
snix system boot NEW_GENERATION --esp /scheme/disk.DEVICE/0p0
```

Replace `NEW_GENERATION` with the active generation ID and the ESP example
with the **verified, unmounted FAT32 EFI partition** on your boot disk, not
the whole disk. The command checks the staged kernel and initfs before
installing the active generation's EFI executable. Reboot only after it
succeeds. To roll back on the same disk, run
`snix system switch-generation OLD_GENERATION`, then
`snix system boot OLD_GENERATION --esp /scheme/disk.DEVICE/0p0` and reboot.

ESP installation replaces the existing `EFI/BOOT/BOOTX64.EFI` fallback
entry. It does not change firmware boot entries or support other EFI paths.
The installer stages and reads back the replacement before publishing it;
power-loss durability depends on the disk backend. Keep recovery media.
If EFI installation fails, restore the previous generation before rebooting.

## Decision

Option 1: grow the native graph in `nix/pkgs/infrastructure/native-system-build.nix`.
The native graph already builds the kernel, bootloader, initfs tools, initfs,
`/etc` and the generation with the seed compiler, and it shares the init-script,
PCI and initfs renderers with the host module system.

- Option 2, a Redox package set in the flake, needs a Redox stdenv equivalent and
  a port of every package before it can produce a bootable image.
- Option 3, shared package data, is the long-term deduplication path, but it is a
  large refactor of `nix/pkgs` and does not unblock a guest build sooner.
- The native graph is exercised by `native-rebuild-test`, `kernel-rebuild-test`
  and `self-hosting-test`; extending it keeps one tested path.

Fetching, patching and vendoring still happen when producing the seed.
Moving these steps into Redox is part of #33.

## Scope

Built in the guest:

- kernel and UEFI bootloader;
- initfs tools, initfs archive, `/etc`, init scripts, PCI configuration;
- the system generation and its package profile;
- Snix from a nix-redox checkout, plus source packages selected by
  `snix system rebuild --source`;
- the fallback EFI executable can be installed by the guest; creating a
  fresh disk image and partitioning it on Redox remain open in #37.

Host-only outputs remain the QEMU and Cloud Hypervisor runners, browser assets
and WASM engines, binary-cache publishing, and the initial seed image.

## Representative output: Snix

1. The image stages the checkout at `/usr/src/snix-redox`, including the
   vendored crates and `build.nix`.
2. The seed `/bin/snix` builds it:

   ```sh
   /bin/snix build --file /usr/src/snix-redox/build.nix
   ```

   The output is `/nix/store/<hash>-snix-self-compiled/bin/snix`.
3. A guest source package copies that binary into a package:

   ```nix
   {
     snix = derivation {
       name = "snix";
       builder = "/nix/system/profile/bin/bash";
       args = [ "-c" "/bin/mkdir -p $out/bin; /bin/cp /nix/store/<hash>-snix-self-compiled/bin/snix $out/bin/snix; /bin/chmod +x $out/bin/snix" ];
       system = "x86_64-unknown-redox";
     };
   }
   ```

   The package file must contain a literal `$out` and pass `$out` in `args`;
   expanding it in the host-generated file makes the builder exit 0 without
   producing an output.
4. `snix system rebuild --source` evaluates the package, switches a generation,
   and the test replaces `/bin/snix` with the installed binary.
5. The installed binary runs the next source rebuild. The opt-in
   `snix-second-build-test` also has it build Snix again.

Evidence: `self-hosting-test` 90/90 and `snix-second-build-test` (one additional
proof test). `snix-install-test` covers the source-package name and `args`
contract directly.

## Source and patch agreement

`nix/pkgs/infrastructure/snix-combined-src.nix` is the single Snix source tree
for the host cross-build, host unit tests, and the guest bundle. The upstream
patches live in `snix-upstream-source.nix`, so both paths consume the same
patched crates.

`nix build .#checks.x86_64-linux.snix-source-agreement` fails if the guest
bundle's combined tree differs from the host tree. The kernel builder
assembles trampolines with the seed's native NASM. The native graph does not
yet rebuild every stage0 tool or userspace package.
