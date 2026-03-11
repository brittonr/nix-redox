# libpng - PNG reference library for Redox OS
#
# libpng is the official PNG reference library. It's required by freetype2,
# cairo, SDL2_image, and many graphics applications.
#
# Depends on zlib.
#
# Source: https://github.com/pnggroup/libpng/archive/refs/tags/v1.6.46.tar.gz
# Output: libpng16.a + headers + pkg-config

{
  pkgs,
  lib,
  redoxTarget,
  relibc,
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

  version = "1.6.46";

  src = pkgs.fetchurl {
    url = "https://github.com/pnggroup/libpng/archive/refs/tags/v${version}.tar.gz";
    hash = "sha256-dnsBk2+WINSrTN9uw0j2Um+GH4JWSLYQsdYEFn3HONI=";
  };

  extractedSrc = pkgs.stdenv.mkDerivation {
    name = "libpng-${version}-src";
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
mkCLibrary.mkLibrary {
  pname = "redox-libpng";
  inherit version;
  src = extractedSrc;
  buildInputs = [ redox-zlib ];

  nativeBuildInputs = [
    pkgs.autoconf
    pkgs.automake
    pkgs.libtool
    pkgs.gnu-config
  ];

  configurePhase = ''
    runHook preConfigure

    cp -r ${extractedSrc}/* .
    chmod -R u+w .

    ${mkCLibrary.crossEnvSetupWithWrapper}
    ${mkCLibrary.mkDepFlags [ redox-zlib ]}

    # Update config.sub for Redox target
    chmod +w config.sub 2>/dev/null || true
    cp ${pkgs.gnu-config}/config.sub config.sub

    # Regenerate autotools files (GitHub archives need this)
    autoreconf -fi

    ./configure \
      --host=${redoxTarget} \
      --build=${pkgs.stdenv.buildPlatform.config} \
      --prefix=$out \
      --disable-shared \
      --enable-static

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    # Build only the library — skip test programs (they use feenableexcept
    # which relibc doesn't have)
    make -j $NIX_BUILD_CORES -C . libpng16.la
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    # Manual install of library, headers, and pkgconfig
    mkdir -p $out/lib $out/include/libpng16 $out/lib/pkgconfig

    # Extract .a from libtool wrapper
    cp .libs/libpng16.a $out/lib/

    # Headers
    cp png.h pngconf.h pnglibconf.h $out/include/
    cp png.h pngconf.h pnglibconf.h $out/include/libpng16/

    # Compat symlinks
    ln -sf libpng16.a $out/lib/libpng.a

    # pkg-config — create both libpng16.pc and libpng.pc
    if [ -f libpng16.pc ]; then
      cp libpng16.pc $out/lib/pkgconfig/
      sed -i "s|^prefix=.*|prefix=$out|" $out/lib/pkgconfig/libpng16.pc
    else
      cat > $out/lib/pkgconfig/libpng16.pc << PCEOF
    prefix=$out
    exec_prefix=''${prefix}
    libdir=''${prefix}/lib
    includedir=''${prefix}/include/libpng16

    Name: libpng
    Description: PNG library
    Version: ${version}
    Requires: zlib
    Libs: -L''${libdir} -lpng16
    Cflags: -I''${includedir}
  PCEOF
    fi
    # libpng.pc is a copy, not a symlink (avoids broken symlink issue)
    cp $out/lib/pkgconfig/libpng16.pc $out/lib/pkgconfig/libpng.pc

    # Verify
    test -f $out/lib/libpng16.a || { echo "ERROR: libpng16.a not built"; exit 1; }
    echo "libpng libraries:"
    ls -la $out/lib/lib*.a

    runHook postInstall
  '';

  meta = with lib; {
    description = "PNG reference library for Redox OS";
    homepage = "http://www.libpng.org/pub/png/libpng.html";
    license = licenses.libpng2;
  };
}
