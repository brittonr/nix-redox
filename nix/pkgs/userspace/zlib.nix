# zlib - Compression library for Redox OS
#
# zlib is the foundational compression library used by nearly everything:
# libpng, curl, git, openssh, python, etc. Building this unlocks a huge
# dependency tree.
#
# Source: zlib.net (upstream, Redox compatible via CHOST cross-compile)
# Outputs: libz.a, zlib.h, zconf.h

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
    url = "https://www.zlib.net/fossils/zlib-1.3.1.tar.gz";
    hash = "sha256-mpOyt9/ax3zrpaVYpYDnRmfdb+3kWFuR7vtg8Dty3yM=";
  };

in
mkCLibrary.mkLibrary {
  pname = "redox-zlib";
  version = "1.3.1";
  src = src;

  nativeBuildInputs = [
    pkgs.gnutar
    pkgs.gzip
  ];

  configurePhase = ''
    runHook preConfigure

    tar xzf ${src}
    cd zlib-1.3.1
    chmod -R u+w .

    ${mkCLibrary.crossEnvSetup}

    # zlib uses CHOST for cross-compilation detection
    env CHOST="${redoxTarget}" \
      ./configure \
        --prefix=$out \
        --static

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    # Build only the static library — skip test binaries (example, minigzip)
    # which fail to link because our LDFLAGS use -nostdlib
    make -j $NIX_BUILD_CORES libz.a
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    # Manual install of just the library and headers
    mkdir -p $out/lib $out/include $out/lib/pkgconfig
    cp libz.a $out/lib/
    cp zlib.h zconf.h $out/include/
    cp zlib.pc $out/lib/pkgconfig/
    # Fix prefix in pkgconfig
    sed -i "s|^prefix=.*|prefix=$out|" $out/lib/pkgconfig/zlib.pc
    runHook postInstall
  '';

  meta = with lib; {
    description = "Compression library for Redox OS";
    homepage = "https://www.zlib.net/";
    license = licenses.zlib;
  };
}
