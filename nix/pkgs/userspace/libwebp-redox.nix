# libwebp - WebP image format library for Redox OS
#
# libwebp provides encoders and decoders for the WebP image format.
# Required by gdk-pixbuf, SDL2_image, and modern image pipelines.
#
# Depends on libjpeg, libpng, zlib.
#
# Source: https://chromium.googlesource.com/webm/libwebp
# Output: libwebp.a + libwebpdecoder.a + libwebpdemux.a + headers + pkg-config

{
  pkgs,
  lib,
  redoxTarget,
  relibc,
  redox-zlib,
  redox-libpng,
  redox-libjpeg,
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

  version = "1.5.0";

  src = pkgs.fetchurl {
    url = "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${version}.tar.gz";
    hash = "sha256-fW+rcM+ES/Z2kHe9XXp0iT+P/U37QoYXRXUMY8KlySw=";
  };

  extractedSrc = pkgs.stdenv.mkDerivation {
    name = "libwebp-${version}-src";
    dontUnpack = true;
    nativeBuildInputs = [
      pkgs.gnutar
      pkgs.gzip
    ];
    installPhase = ''
      mkdir -p $out
      tar xf ${src} -C $out --strip-components=1
    '';
  };

in
mkCLibrary.mkCmake {
  pname = "redox-libwebp";
  inherit version;
  src = extractedSrc;
  buildInputs = [
    redox-zlib
    redox-libpng
    redox-libjpeg
  ];

  cmakeFlags = [
    "-DBUILD_SHARED_LIBS=OFF"
    "-DWEBP_BUILD_CWEBP=OFF"
    "-DWEBP_BUILD_DWEBP=OFF"
    "-DWEBP_BUILD_IMG2WEBP=OFF"
    "-DWEBP_BUILD_GIF2WEBP=OFF"
    "-DWEBP_BUILD_VWEBP=OFF"
    "-DWEBP_BUILD_WEBPINFO=OFF"
    "-DWEBP_BUILD_WEBPMUX=OFF"
    "-DWEBP_BUILD_EXTRAS=OFF"
    "-DWEBP_BUILD_ANIM_UTILS=OFF"
    "-DWEBP_ENABLE_SWAP_16BIT_CSP=OFF"
    # Link against our cross-compiled libraries
    "-DZLIB_LIBRARY=${redox-zlib}/lib/libz.a"
    "-DZLIB_INCLUDE_DIR=${redox-zlib}/include"
    "-DPNG_LIBRARY=${redox-libpng}/lib/libpng16.a"
    "-DPNG_PNG_INCLUDE_DIR=${redox-libpng}/include"
    "-DJPEG_LIBRARY=${redox-libjpeg}/lib/libjpeg.a"
    "-DJPEG_INCLUDE_DIR=${redox-libjpeg}/include"
  ];

  postInstall = ''
    # Verify
    test -f $out/lib/libwebp.a || { echo "ERROR: libwebp.a not built"; exit 1; }
    echo "libwebp libraries:"
    ls -la $out/lib/lib*.a
  '';

  meta = with lib; {
    description = "WebP image format library for Redox OS";
    homepage = "https://developers.google.com/speed/webp/";
    license = licenses.bsd3;
  };
}
