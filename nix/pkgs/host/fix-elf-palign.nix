# fix-elf-palign: Patch ELF program headers with p_align=0 to p_align=1
#
# Host-only build tool used by the rootTree derivation.
# Replaces the inline Python ELF patcher.

{ pkgs }:

pkgs.rustPlatform.buildRustPackage {
  pname = "fix-elf-palign";
  version = "0.1.0";
  src = ./fix-elf-palign;
  cargoLock.lockFile = ./fix-elf-palign/Cargo.lock;
}
