# fontconfig - Font configuration and matching library for Redox OS
#
# fontconfig provides font discovery and matching for applications.
# Required by: cairo, pango, gtk3, and most text rendering.
#
# Depends on: expat, freetype2, libpng, zlib
# Build system: autotools (not meson, unlike most GNOME libs)
#
# Source: https://www.freedesktop.org/software/fontconfig/release/
# Output: libfontconfig.a + headers + pkg-config

{
  pkgs,
  lib,
  redoxTarget,
  relibc,
  redox-expat,
  redox-freetype2,
  redox-libpng,
  redox-zlib,
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

  version = "2.16.0";

  src = pkgs.fetchurl {
    url = "https://www.freedesktop.org/software/fontconfig/release/fontconfig-${version}.tar.xz";
    hash = "sha256-Y/cLMkW1MYSmGHkJxS5GK6aeKNJvvbSBKRFCJxGdm4E=";
  };

  extractedSrc = pkgs.stdenv.mkDerivation {
    name = "fontconfig-${version}-src";
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

  buildInputs = [
    redox-expat
    redox-freetype2
    redox-libpng
    redox-zlib
  ];

in
mkCLibrary.mkAutotools {
  pname = "redox-fontconfig";
  inherit version buildInputs;

  src = extractedSrc;

  nativeBuildInputs = [
    pkgs.gperf
    pkgs.python3
    pkgs.gnu-config
  ];

  configureFlags = [
    "--disable-shared"
    "--enable-static"
    "--disable-docs"
    # Tell configure that XML_SetDoctypeDeclHandler exists (cross-compile can't test)
    "ac_cv_func_XML_SetDoctypeDeclHandler=yes"
  ];

  preConfigure = ''
    # Use CC wrapper for configure link tests
    export CC="${mkCLibrary.ccWrapper}"
    export LDFLAGS="--target=${redoxTarget} --sysroot=${relibc}/${redoxTarget} -L${relibc}/${redoxTarget}/lib -static -fuse-ld=lld"

    # freetype2 headers need -I.../include/freetype2
    export CFLAGS="$CFLAGS -I${redox-freetype2}/include/freetype2"

    # Tell configure where to find libraries explicitly
    export FREETYPE_CFLAGS="-I${redox-freetype2}/include/freetype2"
    export FREETYPE_LIBS="-L${redox-freetype2}/lib -lfreetype"
    export EXPAT_CFLAGS="-I${redox-expat}/include"
    export EXPAT_LIBS="-L${redox-expat}/lib -lexpat"

    # Link against libpng and zlib (freetype2 needs them)
    export LIBS="-lpng -lz"
    export V=1

    # Replace config.sub for Redox target
    chmod +w config.sub 2>/dev/null || true
    cp ${pkgs.gnu-config}/config.sub config.sub
  '';

  postInstall = ''
    test -f $out/lib/libfontconfig.a || { echo "ERROR: libfontconfig.a not built"; exit 1; }
    echo "fontconfig libraries:"
    ls -la $out/lib/lib*.a
  '';

  meta = with lib; {
    description = "Font configuration and matching library for Redox OS";
    homepage = "https://www.freedesktop.org/wiki/Software/fontconfig/";
    license = licenses.mit;
  };
}
