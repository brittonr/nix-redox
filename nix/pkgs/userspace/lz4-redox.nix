# lz4 - Fast lossless compression library for Redox OS
#
# LZ4 is an extremely fast compression algorithm. Required by libarchive
# and used by many high-performance applications.
#
# Source: https://github.com/lz4/lz4
# Output: liblz4.a + headers + pkg-config

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

  version = "1.10.0";

  src = pkgs.fetchurl {
    url = "https://github.com/lz4/lz4/releases/download/v${version}/lz4-${version}.tar.gz";
    hash = "sha256-U3USkEdEs14jKRIFXM+Oxm12hjn/Or5XiNkNeS7F9Is=";
  };

in
mkCLibrary.mkLibrary {
  pname = "redox-lz4";
  inherit version;
  src = src;

  nativeBuildInputs = [
    pkgs.gnutar
    pkgs.gzip
  ];

  configurePhase = ''
    runHook preConfigure

    tar xzf ${src}
    cd lz4-${version}
    chmod -R u+w .

    ${mkCLibrary.crossEnvSetup}

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    # Build only the static library in lib/ — not the CLI tools or tests
    make -C lib -j $NIX_BUILD_CORES liblz4.a \
      CC="$CC" \
      AR="$AR" \
      CFLAGS="$CFLAGS" \
      TARGET_OS=Redox
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib $out/include $out/lib/pkgconfig

    cp lib/liblz4.a $out/lib/
    cp lib/lz4.h lib/lz4hc.h lib/lz4frame.h $out/include/
    # Also copy lz4frame_static.h if it exists
    cp lib/lz4frame_static.h $out/include/ 2>/dev/null || true

    # Generate pkg-config file
    cat > $out/lib/pkgconfig/liblz4.pc << EOF
    prefix=$out
    libdir=''${prefix}/lib
    includedir=''${prefix}/include

    Name: lz4
    Description: LZ4 - Extremely fast compression
    Version: ${version}
    Libs: -L''${libdir} -llz4
    Cflags: -I''${includedir}
  EOF

    # Verify
    test -f $out/lib/liblz4.a || { echo "ERROR: liblz4.a not built"; exit 1; }
    echo "lz4 libraries:"
    ls -la $out/lib/lib*.a

    runHook postInstall
  '';

  meta = with lib; {
    description = "Fast lossless compression library for Redox OS";
    homepage = "https://lz4.org/";
    license = with licenses; [
      bsd2
      gpl2Plus
    ];
  };
}
