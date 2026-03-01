# freetype2 - Font rendering engine for Redox OS
#
# FreeType is a freely available software library to render fonts.
# Required by fontconfig, cairo, pango, SDL2_ttf, harfbuzz, and the
# entire text rendering stack.
#
# Depends on zlib and libpng.
#
# Source: https://sourceforge.net/projects/freetype/files/freetype2/
# Output: libfreetype.a + headers + pkg-config

{
  pkgs,
  lib,
  redoxTarget,
  relibc,
  redox-zlib,
  redox-libpng,
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

  version = "2.13.3";

  src = pkgs.fetchurl {
    url = "https://sourceforge.net/projects/freetype/files/freetype2/${version}/freetype-${version}.tar.xz/download";
    hash = "sha256-BVA1BmbUJ8dNrrhdWse7NTrLpfdpVjlZlTEanG8GMok=";
    name = "freetype-${version}.tar.xz";
  };

  extractedSrc = pkgs.stdenv.mkDerivation {
    name = "freetype-${version}-src";
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
mkCLibrary.mkCmake {
  pname = "redox-freetype2";
  inherit version;
  src = extractedSrc;
  buildInputs = [
    redox-zlib
    redox-libpng
  ];

  cmakeFlags = [
    "-DBUILD_SHARED_LIBS=OFF"
    "-DFT_DISABLE_HARFBUZZ=ON"
    "-DFT_DISABLE_BROTLI=ON"
    "-DFT_DISABLE_BZIP2=ON"
    "-DFT_REQUIRE_ZLIB=ON"
    "-DFT_REQUIRE_PNG=ON"
    "-DZLIB_LIBRARY=${redox-zlib}/lib/libz.a"
    "-DZLIB_INCLUDE_DIR=${redox-zlib}/include"
    "-DPNG_LIBRARY=${redox-libpng}/lib/libpng16.a"
    "-DPNG_PNG_INCLUDE_DIR=${redox-libpng}/include"
  ];

  postInstall = ''
    # Verify
    test -f $out/lib/libfreetype.a || { echo "ERROR: libfreetype.a not built"; exit 1; }
    echo "freetype2 libraries:"
    ls -la $out/lib/lib*.a
  '';

  meta = with lib; {
    description = "Font rendering engine for Redox OS";
    homepage = "https://freetype.org/";
    license = licenses.ftl;
  };
}
