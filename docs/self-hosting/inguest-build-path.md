# In-guest build path

This records the decision for [#43](https://github.com/brittonr/nix-redox/issues/43):
nix-redox keeps one guest-native build graph and feeds it from pinned sources.
The host produces the seed image; later builds run in the guest.

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

Source preparation is host-side until #33 moves it into the guest. That is a
known boundary, not a second build definition.

## Scope

Built in the guest:

- kernel and UEFI bootloader;
- initfs tools, initfs archive, `/etc`, init scripts, PCI configuration;
- the system generation and its package profile;
- Snix from a nix-redox checkout, plus source packages selected by
  `snix system rebuild --source`;
- disk image and ESP writes are the target of #37.

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
bundle's combined tree differs from the host tree. Other native-graph packages
are copied from the host derivations into the bundle, so they have no second
source definition to drift.
