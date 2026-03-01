# games - Collection of terminal games for Redox OS
#
# A collection of small terminal games including minesweeper, ice,
# h4xx3r, and more. Written in Rust for Redox OS.
#
# Source: gitlab.redox-os.org/redox-os/games (Redox-native)
# Binaries: minesweeper, ice, h4xx3r, rusthello

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  games-src,
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
mkUserspace.mkMultiBinary {
  pname = "redox-games";
  src = games-src;
  binaries = [
    "minesweeper"
    "ice"
    "h4xx3r"
    "rusthello"
  ];

  vendorHash = "sha256-NaoWcFvqskF3omld5m8rWQwVvVatQVllkLAbXmBMdGg=";

  gitSources = [
    {
      url = "git+https://gitlab.redox-os.org/redox-os/liner.git";
      git = "https://gitlab.redox-os.org/redox-os/liner.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/libextra.git";
      git = "https://gitlab.redox-os.org/redox-os/libextra.git";
    }
    {
      url = "git+https://github.com/EGhiorzi/reversi/";
      git = "https://github.com/EGhiorzi/reversi/";
    }
  ];

  meta = with lib; {
    description = "Collection of terminal games for Redox OS";
    homepage = "https://gitlab.redox-os.org/redox-os/games";
    license = licenses.mit;
  };
}
