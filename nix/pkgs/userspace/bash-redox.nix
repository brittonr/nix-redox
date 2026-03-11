# bash - GNU Bourne-Again Shell for Redox OS
#
# bash is the standard Unix shell used by most scripts and build systems.
# Essential for self-hosting: running configure scripts, Makefiles, etc.
#
# Dependencies: readline (we have it), ncurses (we have it)
# Gettext skipped via --disable-nls for now.
#
# Extensive Redox-specific patches from upstream cookbook:
# - group completion disabled (__redox__ guard)
# - ulimit: HAVE_RESOURCE guarded against __redox__
# - config-top.h: BROKEN_DIRENT_D_INO defined
# - configure: bash_malloc disabled for *-redox*
# - execute_cmd.c: HAVE_GETTIMEOFDAY guard
# - general.c: check_dev_tty disabled on Redox
# - posixwait.h: force POSIX wait types
# - jobs.c: pgrp/tcsetpgrp ordering fix
# - readline/input.c: HAVE_SELECT fallback
# - readline/terminal.c: __redox__ guard for PC extern
# - getcwd.c: disabled on Redox (relibc provides it)
# - strtoimax.c: disabled on Redox (relibc provides it)
# - Various multibyte guards
#
# Source: https://ftp.gnu.org/gnu/bash/bash-5.2.15.tar.gz
# Binary: bash

{
  pkgs,
  lib,
  redoxTarget,
  relibc,
  redox-readline,
  redox-ncurses,
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

  version = "5.2.15";

  bashPatchesPy = ../patches/bash-redox-patches.py;

  src = pkgs.fetchurl {
    url = "https://ftp.gnu.org/gnu/bash/bash-${version}.tar.gz";
    hash = "sha256-E3IJZbX0/DoNS2HdN+dWXHQdqaW+JO3CrgAYL8GzWIw=";
  };

  extractedSrc = pkgs.stdenv.mkDerivation {
    name = "bash-${version}-src";
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

  buildDeps = [
    redox-readline
    redox-ncurses
  ];

in
mkCLibrary.mkLibrary {
  pname = "redox-bash";
  inherit version;
  src = extractedSrc;
  buildInputs = buildDeps;

  configurePhase = ''
          runHook preConfigure

          cp -r ${extractedSrc}/* .
          chmod -R u+w .

          # === Redox patches (from upstream cookbook redox.patch) ===
          # Using Python for complex multi-line patches to avoid sed quoting issues

          ${pkgs.python3}/bin/python3 ${bashPatchesPy}

          # Update config.sub for Redox target
          cp ${pkgs.gnu-config}/config.sub support/config.sub 2>/dev/null || true

          # Create stub doc/Makefile.in (we don't need docs)
          mkdir -p doc
          cat > doc/Makefile.in << 'DOCEOF'
      all:
      install:
      clean:
      distclean:
    DOCEOF
          touch doc/make.1

          # Fix timestamps: touch everything uniformly AFTER patching.
          # This prevents make from trying to regenerate configure from configure.ac.
          find . -type f -exec touch -t 202501010000 {} +
          # Then make configure newer than configure.ac
          sleep 1
          touch configure

          ${mkCLibrary.crossEnvSetupWithWrapper}
          ${mkCLibrary.mkDepFlags buildDeps}

          # bash 5.2 has many K&R declarations and unguarded HANDLE_MULTIBYTE references.
          # Clang 21 is stricter than GCC about these — relax to allow compilation.
          export CFLAGS="$CFLAGS -Wno-error -Wno-implicit-function-declaration -Wno-implicit-int -Wno-deprecated-non-prototype"
          # Allow duplicate symbols (bash bundles mktime/getopt, relibc also has them)
          export LDFLAGS="$LDFLAGS -Wl,--allow-multiple-definition"

          # CC_FOR_BUILD: host compiler for build-time tools (mkbuiltins, etc.)
          export CC_FOR_BUILD="gcc"

          ./configure \
            --host=${redoxTarget} \
            --build=${pkgs.stdenv.buildPlatform.config} \
            --prefix=$out \
            --enable-static-link \
            --disable-nls \
            --disable-multibyte \
            --without-bash-malloc \
            ac_cv_func_wcwidth=no \
            bash_cv_func_sigsetjmp=no \
            bash_cv_getenv_redef=no \
            bash_cv_must_reinstall_sighandlers=no \
            bash_cv_func_strcoll_broken=no \
            bash_cv_func_ctype_nonascii=no \
            bash_cv_dup2_broken=no \
            bash_cv_pgrp_pipe=no \
            bash_cv_sys_siglist=no \
            bash_cv_under_sys_siglist=no \
            bash_cv_opendir_not_robust=no \
            bash_cv_printf_a_format=no

          # Fix builtins/Makefile: remove -DHAVE_CONFIG_H from CCFLAGS_FOR_BUILD
          # config.h is for the cross target — build tools must not use it.
          # Also add -std=gnu89 for GCC 15 compatibility (K&R function declarations).
          sed -i 's/-DHAVE_CONFIG_H//' builtins/Makefile 2>/dev/null || true
          sed -i 's/CC_FOR_BUILD = .*/CC_FOR_BUILD = gcc -std=gnu89/' builtins/Makefile 2>/dev/null || true

          runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    # Parallel make has bugs in bash — use single job (per upstream recipe)
    make -j1
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    make install

    test -f $out/bin/bash || { echo "ERROR: bash binary not built"; exit 1; }
    file $out/bin/bash

    # Create sh symlink (many scripts expect /bin/sh = bash)
    ln -sf bash $out/bin/sh

    rm -rf $out/share/man $out/share/doc $out/share/info $out/share/locale 2>/dev/null || true

    runHook postInstall
  '';

  meta = with lib; {
    description = "GNU Bourne-Again Shell for Redox OS";
    homepage = "https://www.gnu.org/software/bash/";
    license = licenses.gpl3Plus;
  };
}
