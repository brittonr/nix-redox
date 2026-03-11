# libgif (giflib) - GIF image library for Redox OS
#
# giflib is a library for reading and writing GIF images.
# Required by gdk-pixbuf, SDL2_image, and image viewers.
#
# Source: https://sourceforge.net/projects/giflib/
# Output: libgif.a + headers

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

  version = "5.2.2";

  src = pkgs.fetchurl {
    url = "https://sourceforge.net/projects/giflib/files/giflib-${version}.tar.gz/download";
    hash = "sha256-vn/70FfK3r4qoURUL9kMaDjGoIO16KkEi47jtmsp1fs=";
    name = "giflib-${version}.tar.gz";
  };

in
mkCLibrary.mkLibrary {
  pname = "redox-libgif";
  inherit version;
  src = src;

  nativeBuildInputs = [
    pkgs.gnutar
    pkgs.gzip
  ];

  configurePhase = ''
    runHook preConfigure

    tar xzf ${src}
    cd giflib-${version}
    chmod -R u+w .

    ${mkCLibrary.crossEnvSetup}

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    # giflib's Makefile builds both library and utils — just build the .o files and archive
    $CC $CFLAGS -c dgif_lib.c egif_lib.c gifalloc.c gif_err.c gif_font.c \
      gif_hash.c openbsd-reallocarray.c
    $AR rcs libgif.a dgif_lib.o egif_lib.o gifalloc.o gif_err.o gif_font.o \
      gif_hash.o openbsd-reallocarray.o
    $RANLIB libgif.a
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib $out/include $out/lib/pkgconfig

    cp libgif.a $out/lib/
    cp gif_lib.h $out/include/

    # Generate pkg-config file
    cat > $out/lib/pkgconfig/libgif.pc << EOF
    prefix=$out
    libdir=''${prefix}/lib
    includedir=''${prefix}/include

    Name: giflib
    Description: GIF image format library
    Version: ${version}
    Libs: -L''${libdir} -lgif
    Cflags: -I''${includedir}
  EOF

    # Verify
    test -f $out/lib/libgif.a || { echo "ERROR: libgif.a not built"; exit 1; }
    echo "giflib libraries:"
    ls -la $out/lib/lib*.a

    runHook postInstall
  '';

  meta = with lib; {
    description = "GIF image library for Redox OS";
    homepage = "https://giflib.sourceforge.net/";
    license = licenses.mit;
  };
}
