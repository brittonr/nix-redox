# pkgutils - Package management CLI for Redox OS
#
# pkgutils provides the pkg command for installing, removing, and managing
# packages on Redox OS. It's the native package manager.
#
# Source: gitlab.redox-os.org/redox-os/pkgutils (Redox-native)
# Binary: pkg (from pkg-cli workspace member)

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
  version = "0.2.9";
  src = pkgutils-src;
  cargoBuildFlags = "--manifest-path pkg-cli/Cargo.toml";

  vendorHash = "sha256-JNfrHJu/H3+M9PSHYS+MQs2mBjl238YFP7TGJlFTqiw=";

  gitSources = [
    {
      url = "git+https://gitlab.redox-os.org/redox-os/ring.git?branch=redox-0.17.8";
      git = "https://gitlab.redox-os.org/redox-os/ring.git";
      branch = "redox-0.17.8";
    }
    {
      url = "git+https://github.com/tea/cc-rs?branch=riscv-abi-arch-fix";
      git = "https://github.com/tea/cc-rs";
      branch = "riscv-abi-arch-fix";
    }
  ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp target/${redoxTarget}/release/pkg $out/bin/ 2>/dev/null || true
    runHook postInstall
  '';

  meta = with lib; {
    description = "Package management CLI for Redox OS";
    homepage = "https://gitlab.redox-os.org/redox-os/pkgutils";
    license = licenses.mit;
    mainProgram = "pkg";
  };
}
