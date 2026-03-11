# git - Distributed version control system for Redox OS
#
# Git 2.13.1 cross-compiled for Redox. Uses the upstream Redox patch set
# which adds:
# - /scheme/null instead of /dev/null
# - SIG_DFL/SIG_IGN/SIG_ERR defines
# - Redox-specific terminal prompt (no termios)
# - syslog removal, setsid guard
# - Hard link → symlink fallback (Redox lacks hard links)
# - endian.h include for bswap
#
# Dependencies: curl, expat, openssl, zlib (all already built)
#
# Source: https://www.kernel.org/pub/software/scm/git/git-2.13.1.tar.xz
# Output: git binary + subcommands + templates

{
  pkgs,
  lib,
  redoxTarget,
  relibc,
  redox-curl,
  redox-expat,
  redox-openssl,
  redox-zlib,
  ...
}:

let
  gitPatchesPy = ../patches/git-redox-patches.py;
  gitTerminalPy = ../patches/git-redox-terminal.py;

  mkCLibrary = import ./mk-c-library.nix {
    inherit
      pkgs
      lib
      redoxTarget
      relibc
      ;
  };

  version = "2.13.1";

  src = pkgs.fetchurl {
    url = "https://www.kernel.org/pub/software/scm/git/git-${version}.tar.xz";
    hash = "sha256-O8G+zZg/d6sVSkaAFiQ2nbxAw90EtMSwetAm9WhGiP4=";
  };

  buildDeps = [
    redox-curl
    redox-expat
    redox-openssl
    redox-zlib
  ];

  sysroot = "${relibc}/${redoxTarget}";

in
pkgs.stdenv.mkDerivation {
  pname = "redox-git";
  inherit version;

  dontUnpack = true;
  dontFixup = true;

  nativeBuildInputs = with pkgs; [
    llvmPackages.clang
    llvmPackages.bintools
    llvmPackages.lld
    gnumake
    pkg-config
    gnutar
    xz
    python3
    gettext
  ];

  configurePhase = ''
        runHook preConfigure

        tar xf ${src}
        cd git-${version}
        chmod -R u+w .

        # === Apply Redox patches via external Python scripts ===
        ${pkgs.python3}/bin/python3 ${gitPatchesPy}

        # 2b. terminal.c: add Redox terminal prompt before the final #else block
        ${pkgs.python3}/bin/python3 ${gitTerminalPy}

        # 6. Makefile: remove hard link attempts (Redox lacks hard links)
        # Delete lines containing 'ln "$<"' or 'ln "$$' (hard link attempts)
        # Keep 'ln -s' lines (symlinks work fine)
        grep -n 'ln "\$' Makefile | grep -v 'ln -s' | cut -d: -f1 | sort -rn | while read line; do
          sed -i "''${line}d" Makefile
        done

        # Set up cross-compilation environment
        ${mkCLibrary.crossEnvSetupWithWrapper}
        ${mkCLibrary.mkDepFlags buildDeps}

        # Clang relaxations for old C code
        export CFLAGS="$CFLAGS -Wno-error -Wno-implicit-function-declaration -Wno-implicit-int -Wno-deprecated-non-prototype"




        # Allow duplicate symbols (git bundles some libc functions)
        export LDFLAGS="$LDFLAGS -Wl,--allow-multiple-definition"

        # Point to our cross-compiled curl
        export CURL_CONFIG="false"  # Don't use curl-config (host binary)

        ./configure \
          --host=${redoxTarget} \
          --build=${pkgs.stdenv.buildPlatform.config} \
          --prefix=$out \
          ac_cv_fread_reads_directories=yes \
          ac_cv_snprintf_returns_bogus=yes \
          ac_cv_lib_curl_curl_global_init=yes

        runHook postConfigure

        # AFTER configure: append overrides to config.mak.autogen.
        # configure detects NO_REGEX (relibc lacks REG_STARTEND) — we override
        # since git-compat-util.h now defines REG_STARTEND=0.
        # Also disable perl (not available on Redox).
        cat >> config.mak.autogen << 'CFGEOF'
    NO_REGEX =
    NO_PERL = 1
    NO_ICONV = 1
    NEEDS_LIBICONV =
    NEEDS_SSL_WITH_CURL = 1
    NEEDS_CRYPTO_WITH_SSL = 1
    BLK_SHA1 = 1
  CFGEOF
  '';

  buildPhase = ''
    runHook preBuild

    make -j $NIX_BUILD_CORES V=1

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    make install DESTDIR=$out/destdir

    # Move installed files from DESTDIR/prefix to $out
    mv $out/destdir/$out/* $out/ || mv $out/destdir/usr/* $out/ || true
    rm -rf $out/destdir

    # Remove man pages (save space)
    rm -rf $out/share/man $out/share/doc

    # Verify
    test -f $out/bin/git || { echo "ERROR: git binary not built"; exit 1; }
    file $out/bin/git
    echo "git built successfully"
    ls $out/bin/ | head -20

    runHook postInstall
  '';

  meta = with lib; {
    description = "Distributed version control system for Redox OS";
    homepage = "https://git-scm.com/";
    license = licenses.gpl2Only;
  };
}
