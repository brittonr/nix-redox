# bzip2 - Block-sorting file compression library for Redox OS
#
# bzip2 provides high-quality data compression. Required by libarchive,
# python, and many archive tools.
#
# Source: https://sourceware.org/pub/bzip2/
# Output: libbz2.a + headers

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

  version = "1.0.8";

  src = pkgs.fetchurl {
    url = "https://sourceware.org/pub/bzip2/bzip2-${version}.tar.gz";
    hash = "sha256-q1oDF27hBtPw+pDjgdpHjdrkBZGBU8yiSOaCzQxKImk=";
  };

in
mkCLibrary.mkLibrary {
  pname = "redox-bzip2";
  inherit version;
  src = src;

  nativeBuildInputs = [
    pkgs.gnutar
    pkgs.gzip
  ];

  configurePhase = ''
    runHook preConfigure

    tar xzf ${src}
    cd bzip2-${version}
    chmod -R u+w .

    ${mkCLibrary.crossEnvSetup}

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    # Build only the static library — not the binary tools (they need full libc linking)
    make -j $NIX_BUILD_CORES libbz2.a \
      CC="$CC" \
      AR="$AR" \
      RANLIB="$RANLIB" \
      CFLAGS="$CFLAGS -D_FILE_OFFSET_BITS=64"
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib $out/include $out/lib/pkgconfig

    cp libbz2.a $out/lib/
    cp bzlib.h $out/include/

    # Generate pkg-config file
    cat > $out/lib/pkgconfig/bzip2.pc << EOF
    prefix=$out
    libdir=''${prefix}/lib
    includedir=''${prefix}/include

    Name: bzip2
    Description: Block-sorting file compressor library
    Version: ${version}
    Libs: -L''${libdir} -lbz2
    Cflags: -I''${includedir}
  EOF

    # Verify
    test -f $out/lib/libbz2.a || { echo "ERROR: libbz2.a not built"; exit 1; }
    echo "bzip2 libraries:"
    ls -la $out/lib/lib*.a

    runHook postInstall
  '';

  meta = with lib; {
    description = "Block-sorting file compression library for Redox OS";
    homepage = "https://sourceware.org/bzip2/";
    license = licenses.bsdOriginal;
  };
}
