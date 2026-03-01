# libjpeg-turbo - JPEG image codec for Redox OS
#
# libjpeg-turbo is a JPEG image codec that uses SIMD instructions to
# accelerate JPEG compression/decompression. API-compatible with libjpeg.
# Required by gdk-pixbuf, SDL2_image, libtiff, and many image apps.
#
# Source: https://github.com/libjpeg-turbo/libjpeg-turbo
# Output: libjpeg.a + libturbojpeg.a + headers + pkg-config

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

  version = "3.1.0";

  src = pkgs.fetchurl {
    url = "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/${version}/libjpeg-turbo-${version}.tar.gz";
    hash = "sha256-lWTHKx39HW/mJ0xflajZibWYVFddS77kSt57wXqpvJM=";
  };

  extractedSrc = pkgs.stdenv.mkDerivation {
    name = "libjpeg-turbo-${version}-src";
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

  targetArch = builtins.head (lib.splitString "-" redoxTarget);
  cc = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang";
  ar = "${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-ar";
  ranlib = "${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-ranlib";
  sysroot = "${relibc}/${redoxTarget}";
  baseCFlags = "--target=${redoxTarget} --sysroot=${sysroot} -D__redox__ -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -I${sysroot}/include -fPIC";
  baseLdFlags = "--target=${redoxTarget} --sysroot=${sysroot} -L${sysroot}/lib -static -nostdlib";

in
mkCLibrary.mkLibrary {
  pname = "redox-libjpeg";
  inherit version;
  src = extractedSrc;

  nativeBuildInputs = [
    pkgs.cmake
    pkgs.nasm
  ];

  configurePhase = ''
    runHook preConfigure

    cp -r ${extractedSrc}/* .
    chmod -R u+w .

    mkdir -p build && cd build

    cmake .. \
      -DCMAKE_INSTALL_PREFIX=$out \
      -DCMAKE_SYSTEM_NAME=Redox \
      -DCMAKE_SYSTEM_PROCESSOR=${targetArch} \
      -DCMAKE_C_COMPILER=${cc} \
      -DCMAKE_AR=${ar} \
      -DCMAKE_RANLIB=${ranlib} \
      -DCMAKE_FIND_ROOT_PATH="${sysroot}" \
      -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
      -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
      -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
      -DCMAKE_C_FLAGS="${baseCFlags}" \
      -DCMAKE_EXE_LINKER_FLAGS="${baseLdFlags}" \
      -DENABLE_STATIC=ON \
      -DENABLE_SHARED=OFF \
      -DWITH_TURBOJPEG=ON \
      -DWITH_SIMD=OFF \
      -DWITH_JAVA=OFF \
      -DWITH_ARITH_ENC=ON \
      -DWITH_ARITH_DEC=ON

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    # Build ONLY the static library targets, not the CLI tools.
    # configurePhase already cd'd into build/
    cmake --build . --target jpeg-static --parallel $NIX_BUILD_CORES
    cmake --build . --target turbojpeg-static --parallel $NIX_BUILD_CORES || true
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib $out/include $out/lib/pkgconfig

    # Install static libraries
    cp libjpeg.a $out/lib/
    cp libturbojpeg.a $out/lib/ 2>/dev/null || true

    # Install headers — jconfig.h is in build/, others are in ../src/
    cp jconfig.h $out/include/
    for h in jpeglib.h jmorecfg.h jerror.h turbojpeg.h jconfig.h.in; do
      find .. -name "$h" -exec cp {} $out/include/ \; 2>/dev/null
    done

    # Install pkg-config
    cp pkgscripts/libjpeg.pc $out/lib/pkgconfig/ 2>/dev/null || true
    cp pkgscripts/libturbojpeg.pc $out/lib/pkgconfig/ 2>/dev/null || true
    # Fix prefix
    sed -i "s|^prefix=.*|prefix=$out|" $out/lib/pkgconfig/*.pc 2>/dev/null || true

    # Verify
    test -f $out/lib/libjpeg.a || { echo "ERROR: libjpeg.a not built"; exit 1; }
    echo "libjpeg-turbo libraries:"
    ls -la $out/lib/lib*.a

    runHook postInstall
  '';

  meta = with lib; {
    description = "JPEG image codec (libjpeg-turbo) for Redox OS";
    homepage = "https://libjpeg-turbo.org/";
    license = with licenses; [
      ijg
      bsd3
      zlib
    ];
  };
}
