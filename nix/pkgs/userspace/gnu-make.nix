# gnu-make - GNU Make build tool for Redox OS
#
# GNU Make is the standard build automation tool. This is essential for
# self-hosting: building C/C++ projects from source within Redox.
#
# Patches from upstream Redox cookbook:
# - ar.h not available on Redox (use fallback definitions)
# - getopt1.c/getopt.c: ELIDE_CODE on Redox (relibc provides getopt)
#
# Source: http://ftp.gnu.org/gnu/make/make-4.4.tar.gz
# Binary: make

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

  version = "4.4";

  src = pkgs.fetchurl {
    url = "http://ftp.gnu.org/gnu/make/make-${version}.tar.gz";
    hash = "sha256-WB9NToctp0s5Qch0IViYp9NYAvA3Mr3M7h1KeXkQXRg=";
  };

  extractedSrc = pkgs.stdenv.mkDerivation {
    name = "gnu-make-${version}-src";
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
  pname = "gnu-make";
  inherit version;
  src = extractedSrc;

  configurePhase = ''
        runHook preConfigure

        cp -r ${extractedSrc}/* .
        chmod -R u+w .

        # Patch 1: ar.h not available on Redox — use fallback definitions
        sed -i 's|# if !defined (__ANDROID__) && !defined (__BEOS__)|# if 0|' src/arscan.c

        # Patch 2: ELIDE_CODE for getopt on Redox (relibc provides getopt)
        # Make's getopt conflicts with relibc's getopt — disable make's copy
        sed -i '1i\
    #ifdef __redox__\
    #define ELIDE_CODE\
    #endif' src/getopt1.c src/getopt.c

        # Create stub doc/Makefile.in — prevents doc-related build failures
        mkdir -p doc
        cat > doc/Makefile.in << 'DOCEOF'
    all:
    install:
    clean:
    distclean:
  DOCEOF
        # Also create a dummy man page so the top-level Makefile doesn't fail
        touch doc/make.1

        # Fix timestamps to prevent autotools regeneration
        # Order: aclocal.m4 < configure < config.h.in < Makefile.in
        touch aclocal.m4
        sleep 1
        touch configure
        sleep 1
        find . -name 'config.h.in' -exec touch {} \;
        sleep 1
        find . -name 'Makefile.in' -exec touch {} \;

        ${mkCLibrary.crossEnvSetupWithWrapper}

        # Configure for cross-compilation
        ./configure \
          --host=${redoxTarget} \
          --build=${pkgs.stdenv.buildPlatform.config} \
          --prefix=$out \
          ac_cv_func_mkfifo=no \
          --disable-nls

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

    # Verify
    test -f $out/bin/make || { echo "ERROR: make binary not built"; exit 1; }
    file $out/bin/make

    # Clean up docs
    rm -rf $out/share/man $out/share/doc $out/share/info 2>/dev/null || true

    runHook postInstall
  '';

  meta = with lib; {
    description = "GNU Make build automation tool for Redox OS";
    homepage = "https://www.gnu.org/software/make/";
    license = licenses.gpl3Plus;
  };
}
