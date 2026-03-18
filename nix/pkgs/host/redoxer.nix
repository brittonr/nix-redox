# redoxer - run Redox programs from Linux via KVM
#
# The canonical tool for running Redox programs on a Linux host.
# Downloads/manages a Redox disk image and runs programs inside it via KVM.
# Runs on the host (Linux), not on Redox.
#
# Dependencies: redox_installer, redoxfs, redox_syscall, redox-pkg,
#   tempfile, proc-mounts, toml (all from crates.io)
#
# Source: gitlab.redox-os.org/redox-os/redoxer

{ pkgs, lib, redoxer-src, ... }:

pkgs.rustPlatform.buildRustPackage {
  pname = "redoxer";
  version = "0.2.63";
  src = redoxer-src;

  cargoHash = "sha256-U4tYfYlP/E/B8qBLWSpip0scbiiI7hrnNb7JDNgzqxM=";

  nativeBuildInputs = with pkgs; [
    pkg-config
  ];

  buildInputs = with pkgs; [
    fuse
  ];

  meta = with lib; {
    description = "Run Redox programs from a KVM-capable Linux host";
    homepage = "https://gitlab.redox-os.org/redox-os/redoxer";
    license = licenses.mit;
    mainProgram = "redoxer";
  };
}
