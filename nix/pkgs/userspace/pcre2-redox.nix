# pcre2 - Perl Compatible Regular Expressions library for Redox OS
#
# PCRE2 is the successor to PCRE. It provides Perl-compatible regex matching
# and is used by grep -P, git, PHP, nginx, and many other tools.
#
# No Redox-specific patches needed — autotools cross-compilation works.
#
# Source: https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.45/pcre2-10.45.tar.bz2
# Output: libpcre2-8.a, libpcre2-posix.a + headers + pkg-config

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

  version = "10.45";

  src = pkgs.fetchurl {
    url = "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${version}/pcre2-${version}.tar.bz2";
    hash = "sha256-IVR/NRYSDHVZflswqZLielkqMZULUUDnuL/ePxkgM8Q=";
  };

  extractedSrc = pkgs.stdenv.mkDerivation {
    name = "pcre2-${version}-src";
    dontUnpack = true;
    nativeBuildInputs = [
      pkgs.gnutar
      pkgs.bzip2
    ];
    installPhase = ''
      mkdir -p $out
      tar xf ${src} -C $out --strip-components=1
    '';
  };

in
mkCLibrary.mkAutotools {
  pname = "redox-pcre2";
  inherit version;
  src = extractedSrc;

  nativeBuildInputs = [
    pkgs.autoconf
    pkgs.automake
    pkgs.libtool
    pkgs.gnu-config
  ];

  configureFlags = [
    "--disable-shared"
    "--enable-static"
    "--enable-pcre2-8"
    "--disable-pcre2-16"
    "--disable-pcre2-32"
    "--enable-jit=no"
    "--enable-unicode"
  ];

  preConfigure = ''
    # Update config.sub for Redox target
    chmod +w config.sub 2>/dev/null || true
    cp ${pkgs.gnu-config}/config.sub config.sub
    cp ${pkgs.gnu-config}/config.guess config.guess 2>/dev/null || true

    # Regenerate autotools (in case the tarball is stale)
    autoreconf -fi 2>/dev/null || true

    # Use CC wrapper for working link tests
    export CC="${mkCLibrary.ccWrapper}"
    export CXX="${mkCLibrary.cxxWrapper}"
    export LDFLAGS="--target=${redoxTarget} --sysroot=${relibc}/${redoxTarget} -L${relibc}/${redoxTarget}/lib -static -fuse-ld=lld"

    # Remove doc references from Makefile.in — we don't need docs and
    # the generated Makefile references ~80 doc files we don't have
    sed -i '/^dist_doc_DATA/,/^$/d' Makefile.in 2>/dev/null || true
    sed -i '/^dist_html_DATA/,/^$/d' Makefile.in 2>/dev/null || true
    sed -i 's/ doc\/[^ ]*//g' Makefile.in 2>/dev/null || true
  '';

  postInstall = ''
    # Verify
    test -f $out/lib/libpcre2-8.a || { echo "ERROR: libpcre2-8.a not built"; exit 1; }
    echo "pcre2 libraries:"
    ls -la $out/lib/lib*.a
  '';

  meta = with lib; {
    description = "Perl Compatible Regular Expressions library for Redox OS";
    homepage = "https://www.pcre.org/";
    license = licenses.bsd3;
  };
}
