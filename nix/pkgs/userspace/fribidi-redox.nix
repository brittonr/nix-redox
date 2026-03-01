# fribidi - Unicode bidirectional algorithm library for Redox OS
#
# fribidi implements the Unicode Bidirectional Algorithm (UBA).
# Required by: pango, gtk3 for right-to-left text support.
# No dependencies — standalone library.
#
# Source: https://github.com/fribidi/fribidi/releases/
# Output: libfribidi.a + headers + pkg-config

{
  pkgs,
  lib,
  redoxTarget,
  relibc,
  ...
}:

let
  mkCLibrary = import ./mk-c-library.nix {
    inherit
      pkgs
      lib
      redoxTarget
      relibc
      ;
  };

  version = "1.0.16";

  src = pkgs.fetchurl {
    url = "https://github.com/fribidi/fribidi/releases/download/v${version}/fribidi-${version}.tar.xz";
    hash = "sha256-GxzeWyNdQEeekb4vDoijCeMhTIq0cOyKJ0TYKlqeoFw=";
  };

  extractedSrc = pkgs.stdenv.mkDerivation {
    name = "fribidi-${version}-src";
    dontUnpack = true;
    nativeBuildInputs = [
      pkgs.gnutar
      pkgs.xz
    ];
    installPhase = ''
      mkdir -p $out
      tar xf ${src} -C $out --strip-components=1
    '';
  };

in
mkCLibrary.mkMeson {
  pname = "redox-fribidi";
  inherit version;

  src = extractedSrc;
  buildInputs = [ ];

  mesonFlags = [
    "-Dbin=false"
    "-Dtests=false"
    "-Ddocs=false"
  ];

  postInstall = ''
    test -f $out/lib/libfribidi.a || { echo "ERROR: libfribidi.a not built"; exit 1; }
    echo "fribidi libraries:"
    ls -la $out/lib/lib*.a
  '';

  meta = with lib; {
    description = "Unicode bidirectional algorithm library for Redox OS";
    homepage = "https://github.com/fribidi/fribidi";
    license = licenses.lgpl21Plus;
  };
}
