# xz - LZMA compression library for Redox OS
#
# XZ Utils includes liblzma, a general-purpose data compression library
# with an API similar to zlib. Required by libarchive, elfutils, and
# many archive tools.
#
# Source: https://github.com/tukaani-project/xz
# Output: liblzma.a + headers + pkg-config

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

  version = "5.6.4";

  src = pkgs.fetchurl {
    url = "https://github.com/tukaani-project/xz/releases/download/v${version}/xz-${version}.tar.gz";
    hash = "sha256-Jp4/LlEsvTMUhJmCAU3BmaeyFIz1yRztxttims314Js=";
  };

  extractedSrc = pkgs.stdenv.mkDerivation {
    name = "xz-${version}-src";
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
  pname = "redox-xz";
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

    # xz 5.6+ requires C11 or at least C99. Clang supports both but the
    # configure test fails in cross-compile mode (can't run test programs).
    # Pass -std=c99 in CFLAGS and tell configure we have C99.
    export CFLAGS="$CFLAGS -std=c99"
    export ac_cv_prog_cc_c99=""
  '';

  configureFlags = [
    "--enable-static"
    "--disable-shared"
    "--disable-xz"
    "--disable-xzdec"
    "--disable-lzmadec"
    "--disable-lzmainfo"
    "--disable-scripts"
    "--disable-doc"
    "--disable-nls"
  ];

  postInstall = ''
    # Verify
    test -f $out/lib/liblzma.a || { echo "ERROR: liblzma.a not built"; exit 1; }
    echo "xz/liblzma libraries:"
    ls -la $out/lib/lib*.a
  '';

  meta = with lib; {
    description = "LZMA compression library for Redox OS";
    homepage = "https://tukaani.org/xz/";
    license = with licenses; [
      gpl2Plus
      lgpl21Plus
    ];
  };
}
