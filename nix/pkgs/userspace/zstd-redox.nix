# zstd - Fast compression library for Redox OS
#
# Zstandard provides fast real-time compression. Used by the build bridge
# for NAR compression, and by many other tools.
#
# Source: github.com/facebook/zstd (upstream, plain Makefile build)
# Outputs: libzstd.a, zstd.h

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

  src = pkgs.fetchurl {
    url = "https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz";
    hash = "sha256-6zPlH0mhXgI5UM14Jcp0pKK0Pbg1SCWsJPwbfuCeb6M=";
  };

in
mkCLibrary.mkLibrary {
  pname = "redox-zstd";
  version = "1.5.7";
  src = src;

  nativeBuildInputs = [
    pkgs.gnutar
    pkgs.gzip
  ];

  configurePhase = ''
    runHook preConfigure

    tar xzf ${src}
    cd zstd-1.5.7
    chmod -R u+w .

    ${mkCLibrary.crossEnvSetup}

    # zstd needs -fPIC for static linking into shared objects
    export CPPFLAGS="$CPPFLAGS -fPIC"

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    # Build only the static library — no shared lib (--noexecstack not supported)
    # and no CLI tools (need pthreads / linking against libc)
    make -C lib -j $NIX_BUILD_CORES libzstd.a HAVE_PTHREAD=0
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    # Manual install of just the static library and headers
    mkdir -p $out/lib $out/include $out/lib/pkgconfig
    cp lib/libzstd.a $out/lib/
    cp lib/zstd.h lib/zstd_errors.h lib/zdict.h $out/include/
    # Generate minimal pkgconfig
    cat > $out/lib/pkgconfig/libzstd.pc << EOF
    prefix=$out
    libdir=\''${prefix}/lib
    includedir=\''${prefix}/include

    Name: zstd
    Description: fast lossless compression algorithm library
    URL: https://github.com/facebook/zstd
    Version: 1.5.7
    Libs: -L\''${libdir} -lzstd
    Cflags: -I\''${includedir}
  EOF
    runHook postInstall
  '';

  meta = with lib; {
    description = "Fast compression library for Redox OS";
    homepage = "https://facebook.github.io/zstd/";
    license = with licenses; [
      bsd3
      gpl2Only
    ];
  };
}
