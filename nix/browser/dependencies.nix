# Corresponding source and notices for libraries linked by the pinned Docker
# recipe. These are source inputs, not host nixpkgs replacement libraries.
{ pkgs }:
{
  glib = pkgs.fetchurl {
    url = "https://download.gnome.org/sources/glib/2.75/glib-2.75.0.tar.xz";
    hash = "sha256-bd6OVcxKLIPZZ5cSCwi8/7X2RbLiEhZK4i1jxA4OY2A=";
  };
  pixman = pkgs.fetchurl {
    url = "https://cairographics.org/releases/pixman-0.42.2.tar.gz";
    hash = "sha256-6hSA762i/ZSLx1Nm98NJ4cltMpfQmj/mJibjjiNKYl4=";
  };
  zlib = pkgs.fetchurl {
    url = "https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.xz";
    hash = "sha256-OO+WuN/lENQnB9nHgYd5FHklQRM+GHCEFGO/pz+IPjI=";
  };
  libffi = pkgs.fetchFromGitHub {
    owner = "libffi";
    repo = "libffi";
    rev = "adbcf2b247696dde2667ab552cb93e0c79455c84";
    hash = "sha256-b5nHuni1IdGhwspqo9E0eOEHRbeWlwufcYL4vise6QY=";
  };
  emscripten = pkgs.fetchFromGitHub {
    owner = "emscripten-core";
    repo = "emscripten";
    rev = "047b82506d6b471873300a5e4d1e690420b582d0";
    hash = "sha256-iFZF+DxGaq279QPPugoLhYmoXmyLPkmn1x4rBCkdW+I=";
  };
}
