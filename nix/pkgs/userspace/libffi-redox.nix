# libffi - Foreign Function Interface library for Redox OS
#
# libffi provides a portable, high-level programming interface to various
# calling conventions, allowing code to call any function specified at
# runtime. Required by glib, python, and many language runtimes.
#
# Source: https://github.com/libffi/libffi
# Output: libffi.a + headers + pkg-config

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

  version = "3.4.7";

  src = pkgs.fetchurl {
    url = "https://github.com/libffi/libffi/releases/download/v${version}/libffi-${version}.tar.gz";
    hash = "sha256-E4YH3uJovezzdK35FEwA6DnjhUH3XySh/PGLeP2kiy0=";
  };

  extractedSrc = pkgs.stdenv.mkDerivation {
    name = "libffi-${version}-src";
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
mkCLibrary.mkAutotools {
  pname = "redox-libffi";
  inherit version;
  src = extractedSrc;

  nativeBuildInputs = [ pkgs.gnu-config ];

  preConfigure = ''
    # Update config.sub for Redox target
    find . -name config.sub -exec chmod +w {} \; -exec cp ${pkgs.gnu-config}/config.sub {} \;
    find . -name config.guess -exec chmod +w {} \; -exec cp ${pkgs.gnu-config}/config.guess {} \;

    # Prevent autotools regeneration
    find . -name configure -exec touch {} +
    find . -name Makefile.in -exec touch {} +
    find . -name '*.m4' -exec touch -d '2020-01-01' {} +
    touch -d '2020-01-01' configure.ac 2>/dev/null || true

    # Create stub man/doc dirs (configure expects them)
    for dir in man doc; do
      mkdir -p $dir
      cat > $dir/Makefile.in << 'STUBMK'
    all:
    install:
    clean:
    distclean:
  STUBMK
    done

    # libffi uses assembly for its closures. On x86_64-unknown-redox the ABI
    # is the same as x86_64 SysV. We just need to make sure the assembler
    # is invoked with the right flags.
    export CCASFLAGS="$CFLAGS"
    export CCAS="$CC"
  '';

  configureFlags = [
    "--enable-static"
    "--disable-shared"
    "--disable-docs"
    "--disable-multi-os-directory"
  ];

  postInstall = ''
    # libffi installs headers to lib/libffi-${version}/include — symlink to include/
    if [ -d "$out/lib/libffi-${version}/include" ]; then
      cp -r $out/lib/libffi-${version}/include/* $out/include/ 2>/dev/null || true
    fi

    # Verify
    test -f $out/lib/libffi.a || { echo "ERROR: libffi.a not built"; exit 1; }
    echo "libffi libraries:"
    ls -la $out/lib/lib*.a
  '';

  meta = with lib; {
    description = "Foreign Function Interface library for Redox OS";
    homepage = "https://sourceware.org/libffi/";
    license = licenses.mit;
  };
}
