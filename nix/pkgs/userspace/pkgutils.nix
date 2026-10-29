# pkgutils - Package management CLI for Redox OS
#
# pkgutils provides the pkg command for installing, removing, and managing
# packages on Redox OS. It's the native package manager.
#
# Source: gitlab.redox-os.org/redox-os/pkgutils (Redox-native)
# Binary: pkg (from pkg-cli workspace member)
#
# pkgutils uses upstream's Redox ring fork. Its assembly build needs a .git
# marker so build/main.rs invokes the Perl generators included in the crate.

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  pkgutils-src,
  ...
}:

let
  mkUserspace = import ./mk-userspace.nix {
    inherit
      pkgs
      lib
      rustToolchain
      sysrootVendor
      redoxTarget
      relibc
      stubLibs
      vendor
      ;
  };

in
mkUserspace.mkPackage {
  pname = "pkgutils";
  version = "0.3.3";
  src = pkgutils-src;
  cargoBuildFlags = "--manifest-path pkg-cli/Cargo.toml";

  # Perl needed by ring's build.rs to generate assembly from .pl files
  nativeBuildInputs = [ pkgs.perl ];

  vendorHash = "sha256-Hha+vlyQOjeH+qM+D/t61xLJu/T2iVlvTxlzbM7947Y=";

  gitSources = [
    {
      url = "git+https://gitlab.redox-os.org/redox-os/ring.git?branch=redox-0.17.16";
      git = "https://gitlab.redox-os.org/redox-os/ring.git";
      branch = "redox-0.17.16";
    }
  ];

  # Git vendoring drops .git, but this fork does not ship pregenerated asm.
  # An empty directory selects source generation without replacing crate files.
  postConfigure = ''
    find vendor-combined -maxdepth 1 -name 'ring-*' -type d \
      -exec mkdir -p '{}/.git' \;
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp target/${redoxTarget}/release/pkg $out/bin/
    runHook postInstall
  '';

  meta = with lib; {
    description = "Package management CLI for Redox OS";
    homepage = "https://gitlab.redox-os.org/redox-os/pkgutils";
    license = licenses.mit;
    mainProgram = "pkg";
  };
}
