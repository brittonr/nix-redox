# pixman - Pixel manipulation library for Redox OS
#
# pixman is a low-level pixel manipulation library. It provides
# compositing, trapezoid rasterization, and pixel-level image manipulation.
# Required by cairo (and thus by pango, GTK, and the entire desktop stack).
#
# Source: https://www.cairographics.org/releases/
# Output: libpixman-1.a + headers + pkg-config

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

  version = "0.44.2";

  src = pkgs.fetchurl {
    url = "https://www.cairographics.org/releases/pixman-${version}.tar.gz";
    hash = "sha256-Y0kGHOGjOKtpUrkhlNGwN3RyJEII1H/yW++G/HGXNGY=";
  };

  extractedSrc = pkgs.stdenv.mkDerivation {
    name = "pixman-${version}-src";
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
  pname = "redox-pixman";
  inherit version;
  src = extractedSrc;

  nativeBuildInputs = [
    pkgs.meson
    pkgs.ninja
    pkgs.pkg-config
    pkgs.python3
  ];

  configurePhase = ''
    runHook preConfigure

    cp -r ${extractedSrc}/* .
    chmod -R u+w .

    ${mkCLibrary.crossEnvSetup}

    # Create meson cross-compilation file
    cat > cross-file.txt << CROSS
    [binaries]
    c = '${pkgs.llvmPackages.clang-unwrapped}/bin/clang'
    ar = '${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-ar'
    strip = '${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-strip'
    pkgconfig = '${pkgs.pkg-config}/bin/pkg-config'

    [built-in options]
    c_args = ['--target=${redoxTarget}', '--sysroot=${relibc}/${redoxTarget}', '-D__redox__', '-U_FORTIFY_SOURCE', '-D_FORTIFY_SOURCE=0', '-I${relibc}/${redoxTarget}/include', '-fPIC']
    c_link_args = ['--target=${redoxTarget}', '--sysroot=${relibc}/${redoxTarget}', '-L${relibc}/${redoxTarget}/lib', '-static', '-nostdlib']

    [host_machine]
    system = 'redox'
    cpu_family = 'x86_64'
    cpu = 'x86_64'
    endian = 'little'
  CROSS

    meson setup build \
      --cross-file cross-file.txt \
      --prefix=$out \
      --default-library=static \
      -Dgtk=disabled \
      -Dlibpng=disabled \
      -Dtests=disabled \
      -Ddemos=disabled \
      -Dopenmp=disabled

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    ninja -C build -j $NIX_BUILD_CORES
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    ninja -C build install

    # Verify
    test -f $out/lib/libpixman-1.a || test -f $out/lib/x86_64-unknown-redox/libpixman-1.a || {
      echo "ERROR: libpixman-1.a not built"
      find $out -name '*.a' 2>/dev/null
      exit 1
    }

    # If meson installed to a subdirectory, move files up
    if [ -d "$out/lib/x86_64-unknown-redox" ]; then
      mv $out/lib/x86_64-unknown-redox/* $out/lib/
      rmdir $out/lib/x86_64-unknown-redox
    fi

    echo "pixman libraries:"
    ls -la $out/lib/lib*.a

    runHook postInstall
  '';

  meta = with lib; {
    description = "Pixel manipulation library for Redox OS";
    homepage = "https://www.pixman.org/";
    license = licenses.mit;
  };
}
