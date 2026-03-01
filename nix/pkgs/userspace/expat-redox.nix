# expat - XML parser library for Redox OS
#
# expat is a stream-oriented XML parsing library written in C.
# Used by dbus, fontconfig, git, python, and many other packages.
#
# Source: github.com/libexpat/libexpat (upstream)
# Outputs: libexpat.a, expat.h

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
    url = "https://github.com/libexpat/libexpat/releases/download/R_2_5_0/expat-2.5.0.tar.xz";
    hash = "sha256-7yQg8CMsCHgBq/cF6JrmX2JX32t5MdN4RqGT7y6M3L4=";
  };

  # Extract the tarball into a directory usable by mkLibrary
  extractedSrc = pkgs.stdenv.mkDerivation {
    name = "expat-2.5.0-src";
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

in
mkCLibrary.mkAutotools {
  pname = "redox-expat";
  version = "2.5.0";
  src = extractedSrc;

  preConfigure = ''
    # Create missing doc/Makefile.in to satisfy configure
    mkdir -p doc
    echo 'all:' > doc/Makefile.in
    echo 'install:' >> doc/Makefile.in

    # Prevent autotools from trying to regenerate anything.
    # The Makefile checks timestamps to decide if regeneration is needed.
    # Touch all generated files NEWER than their sources.
    sleep 1
    touch aclocal.m4
    sleep 1
    touch configure expat_config.h.in
    sleep 1
    find . -name Makefile.in -exec touch {} +
    find . -name '*.m4' ! -name 'aclocal.m4' -exec touch -d '2020-01-01' {} +
    touch -d '2020-01-01' configure.ac
  '';

  configureFlags = [
    "--without-docbook"
    "--without-examples"
    "--without-tests"
    "--without-xmlwf"
    "--enable-static"
    "--disable-shared"
  ];

  meta = with lib; {
    description = "XML parser library for Redox OS";
    homepage = "https://libexpat.github.io/";
    license = licenses.mit;
  };
}
