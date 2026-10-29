# redoxer - run Redox programs from Linux via KVM
#
# The canonical tool for running Redox programs on a Linux host.
# Downloads/manages a Redox disk image and runs programs inside it via KVM.
# Runs on the host (Linux), not on Redox.
#
# Includes the upstream cli-pkg and cli-exec features, with fuser/libc for FUSE.
#
# Source: gitlab.redox-os.org/redox-os/redoxer

{ pkgs, lib, redoxer-src, ... }:

pkgs.rustPlatform.buildRustPackage {
  pname = "redoxer";
  version = "0.2.63";
  src = redoxer-src;

  cargoHash = "sha256-bTAysf9KQ7g7y9QfwSqgyLMnjp3xGLLcYcfjqGgngbo=";

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
