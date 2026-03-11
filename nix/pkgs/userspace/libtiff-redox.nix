# libtiff - TIFF image library for Redox OS
#
# libtiff provides support for reading and writing TIFF image files.
# Required by gdk-pixbuf, SDL2_image, and image processing apps.
#
# Depends on zlib and libjpeg.
#
# Source: https://download.osgeo.org/libtiff/
# Output: libtiff.a + headers + pkg-config

{
  pkgs,
  lib,
  redoxTarget,
  relibc,
  redox-zlib,
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

  version = "4.7.0";

  src = pkgs.fetchurl {
    url = "https://download.osgeo.org/libtiff/tiff-${version}.tar.xz";
    hash = "sha256-JzoKc7HwvtZAr+5KXfAzc1fO1bU9PV0cQFuTZQH3EBc=";
  };

  extractedSrc = pkgs.stdenv.mkDerivation {
    name = "tiff-${version}-src";
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

  targetArch = builtins.head (lib.splitString "-" redoxTarget);
  cc = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang";
  ar = "${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-ar";
  ranlib = "${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-ranlib";
  sysroot = "${relibc}/${redoxTarget}";
  baseCFlags = builtins.concatStringsSep " " [
    "--target=${redoxTarget}"
    "--sysroot=${sysroot}"
    "-D__redox__"
    "-U_FORTIFY_SOURCE"
    "-D_FORTIFY_SOURCE=0"
    "-I${sysroot}/include"
    "-I${redox-zlib}/include"
    "-I${redox-libjpeg}/include"
    "-fPIC"
  ];
  baseLdFlags = "--target=${redoxTarget} --sysroot=${sysroot} -L${sysroot}/lib -L${redox-zlib}/lib -L${redox-libjpeg}/lib -static -nostdlib";

in
mkCLibrary.mkLibrary {
  pname = "redox-libtiff";
  inherit version;
  src = extractedSrc;
  buildInputs = [
    redox-zlib
    redox-libjpeg
  ];

  nativeBuildInputs = [ pkgs.cmake ];

  configurePhase = ''
    runHook preConfigure

    cp -r ${extractedSrc}/* .
    chmod -R u+w .

    # relibc includes math functions (pow etc.) in libc — no separate libm.
    # Patch cmake/FindCMath.cmake to just set FOUND=TRUE.
    if [ -f cmake/FindCMath.cmake ]; then
      cat > cmake/FindCMath.cmake << 'CMATHEOF'
    set(CMath_LIBRARY "")
    set(CMath_INCLUDE_DIR "")
    set(CMath_pow TRUE)
    set(CMath_FOUND TRUE)
  CMATHEOF
    fi

    mkdir -p build && cd build

    cmake .. \
      -DCMAKE_INSTALL_PREFIX=$out \
      -DCMAKE_SYSTEM_NAME=Redox \
      -DCMAKE_SYSTEM_PROCESSOR=${targetArch} \
      -DCMAKE_C_COMPILER=${cc} \
      -DCMAKE_CXX_COMPILER=${pkgs.llvmPackages.clang-unwrapped}/bin/clang++ \
      -DCMAKE_AR=${ar} \
      -DCMAKE_RANLIB=${ranlib} \
      -DCMAKE_FIND_ROOT_PATH="${sysroot}" \
      -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
      -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
      -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
      -DCMAKE_C_FLAGS="${baseCFlags}" \
      -DCMAKE_EXE_LINKER_FLAGS="${baseLdFlags}" \
      -DBUILD_SHARED_LIBS=OFF \
      -Dcxx=OFF \
      -Dtiff-tools=OFF \
      -Dtiff-tests=OFF \
      -Dtiff-contrib=OFF \
      -Dtiff-docs=OFF \
      -DZLIB_LIBRARY=${redox-zlib}/lib/libz.a \
      -DZLIB_INCLUDE_DIR=${redox-zlib}/include \
      -DJPEG_LIBRARY_RELEASE=${redox-libjpeg}/lib/libjpeg.a \
      -DJPEG_INCLUDE_DIR=${redox-libjpeg}/include \
      -DCMAKE_C_STANDARD_INCLUDE_DIRECTORIES="${redox-libjpeg}/include;${redox-zlib}/include" \
      -Dwebp=OFF \
      -Dlzma=OFF \
      -Dzstd=OFF \
      -Djbig=OFF \
      -Dlerc=OFF \
      -Dlibdeflate=OFF

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make -j $NIX_BUILD_CORES
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    make install

    test -f $out/lib/libtiff.a || { echo "ERROR: libtiff.a not built"; exit 1; }
    echo "libtiff libraries:"
    ls -la $out/lib/lib*.a

    runHook postInstall
  '';

  meta = with lib; {
    description = "TIFF image library for Redox OS";
    homepage = "http://www.libtiff.org/";
    license = licenses.libtiff;
  };
}
