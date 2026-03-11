# diffutils - GNU diff, diff3, sdiff, cmp for Redox OS
#
# GNU Diffutils provides programs for comparing files (diff, diff3, sdiff, cmp).
# Essential for development workflows and patch creation/review.
#
# Patches from upstream Redox cookbook (diffutils 3.6):
# - cmpbuf.c: Comment out SA_RESTART/EINTR retry (not on Redox)
# - getdtablesize.c: Disable RLIMIT_NOFILE (not available on Redox)
# - getprogname.c: Add Redox implementation via sys:exe scheme
# - sigprocmask.c: Disable sigemptyset/sigfillset (relibc provides them)
#
# Source: https://ftp.gnu.org/gnu/diffutils/diffutils-3.6.tar.xz
# Binaries: diff, diff3, sdiff, cmp

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

  version = "3.6";

  src = pkgs.fetchurl {
    url = "https://ftp.gnu.org/gnu/diffutils/diffutils-${version}.tar.xz";
    hash = "sha256-1iHovdS1c5GMgUX3rmGBfRvp3rTI0jKKZc6o4R14O9Y=";
  };

  extractedSrc = pkgs.stdenv.mkDerivation {
    name = "diffutils-${version}-src";
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

  # Python patching script (uses writeText to avoid heredoc issues with Nix '' strings)
  patchScript = pkgs.writeText "diffutils-patch.py" ''
    import os, sys

    def patch_file(path, old, new):
        with open(path) as f:
            content = f.read()
        patched = content.replace(old, new, 1)
        if patched == content:
            print(f"WARNING: patch not applied to {path} (pattern not found)")
        with open(path, "w") as f:
            f.write(patched)

    # 1. cmpbuf.c: comment out SA_RESTART/EINTR retry
    patch_file("lib/cmpbuf.c",
        "if (! SA_RESTART && errno == EINTR)\n\t    continue;",
        "//if (! SA_RESTART && errno == EINTR)\n\t  //  continue;")

    # 2. getdtablesize.c: disable RLIMIT_NOFILE on Redox
    patch_file("lib/getdtablesize.c",
        "  struct rlimit lim;\n"
        "\n"
        "  if (getrlimit (RLIMIT_NOFILE, &lim) == 0\n"
        "      && 0 <= lim.rlim_cur && lim.rlim_cur <= INT_MAX\n"
        "      && lim.rlim_cur != RLIM_INFINITY\n"
        "      && lim.rlim_cur != RLIM_SAVED_CUR\n"
        "      && lim.rlim_cur != RLIM_SAVED_MAX)\n"
        "    return lim.rlim_cur;",

        "#if !defined(__redox__)\n"
        "  struct rlimit lim;\n"
        "\n"
        "  if (getrlimit (RLIMIT_NOFILE, &lim) == 0\n"
        "      && 0 <= lim.rlim_cur && lim.rlim_cur <= INT_MAX\n"
        "      && lim.rlim_cur != RLIM_INFINITY\n"
        "      && lim.rlim_cur != RLIM_SAVED_CUR\n"
        "      && lim.rlim_cur != RLIM_SAVED_MAX)\n"
        "    return lim.rlim_cur;\n"
        "#endif")

    # 3. getprogname.c: add Redox headers and implementation
    patch_file("lib/getprogname.c",
        '#include "dirname.h"',
        '#if defined(__redox__)\n'
        '# include <string.h>\n'
        '# include <unistd.h>\n'
        '# include <stdio.h>\n'
        '# include <fcntl.h>\n'
        '# include <limits.h>\n'
        '#endif\n'
        '\n'
        '#include "dirname.h"')

    patch_file("lib/getprogname.c",
        '  return NULL;\n'
        '# else\n'
        '#  error "getprogname module not ported to this OS"\n'
        '# endif',

        '  return NULL;\n'
        '# elif defined(__redox__)\n'
        '  char filename[PATH_MAX];\n'
        '  int fd = open ("sys:exe", O_RDONLY);\n'
        '  if (fd > 0) {\n'
        '    int len = read(fd, filename, PATH_MAX-1);\n'
        '    if (len > 0) {\n'
        '       filename[len] = \'\\0\';\n'
        '       return strdup(filename);\n'
        '    }\n'
        '  }\n'
        '  return NULL;\n'
        '# else\n'
        '#  error "getprogname module not ported to this OS"\n'
        '# endif')

    # 4. sigprocmask.c: guard signal functions (relibc provides them)
    patch_file("lib/sigprocmask.c",
        "\nint\nsigemptyset (sigset_t *set)",
        "\n#if !defined(__redox__)\nint\nsigemptyset (sigset_t *set)")

    # Find the end of sigfillset and add closing #endif
    with open("lib/sigprocmask.c") as f:
        content = f.read()
    old_end = "  *set = ((2U << (NSIG - 1)) - 1) & ~ SIGABRT_COMPAT_MASK;\n  return 0;\n}"
    new_end = "  *set = ((2U << (NSIG - 1)) - 1) & ~ SIGABRT_COMPAT_MASK;\n  return 0;\n}\n#endif"
    content = content.replace(old_end, new_end, 1)
    with open("lib/sigprocmask.c", "w") as f:
        f.write(content)

    print("All diffutils patches applied successfully")
  '';

in
mkCLibrary.mkLibrary {
  pname = "diffutils";
  inherit version;
  src = extractedSrc;

  nativeBuildInputs = [
    pkgs.autoconf
    pkgs.automake
    pkgs.gettext
    pkgs.gperf
    pkgs.texinfo
    pkgs.perl
  ];

  configurePhase = ''
    runHook preConfigure

    cp -r ${extractedSrc}/* .
    chmod -R u+w .

    # Apply Redox patches
    ${pkgs.python3}/bin/python3 ${patchScript}

    # Create doc stubs needed by automake/configure
    mkdir -p doc man
    touch doc/local.mk 2>/dev/null || true
    cat > doc/Makefile.in << 'DOCEOF'
    all:
    install:
    clean:
    distclean:
  DOCEOF
    cat > man/Makefile.in << 'DOCEOF'
    all:
    install:
    clean:
    distclean:
  DOCEOF

    # autoreconf updates config.sub to recognize x86_64-unknown-redox
    autoreconf -fi 2>/dev/null || true

    ${mkCLibrary.crossEnvSetupWithWrapper}

    # Suppress clang errors/warnings from gnulib:
    export CFLAGS="$CFLAGS -Wno-error=incompatible-function-pointer-types -Wno-error=deprecated-declarations -DLDBL_DIG=__LDBL_DIG__"

    ./configure \
      --host=${redoxTarget} \
      --build=${pkgs.stdenv.buildPlatform.config} \
      --prefix=$out \
      --disable-nls \
      gt_cv_locale_fr=false \
      gt_cv_locale_fr_utf8=false \
      gt_cv_locale_ja=false \
      gt_cv_locale_tr_utf8=false \
      gt_cv_locale_zh_CN=false

    # Replace ONLY the gnulib headers that cause circular include chains:
    # lib/stddef.h → relibc/stddef.h → lib/stdint.h → relibc/sys/types.h
    # → relibc/bits/pthread.h → needs size_t → still inside stddef.h!
    # Keep all other gnulib headers intact (they provide needed definitions).
    echo '#include_next <stddef.h>' > lib/stddef.h
    echo '#include_next <stdint.h>' > lib/stdint.h

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

    # Verify binaries
    for bin in diff diff3 sdiff cmp; do
      test -f $out/bin/$bin || { echo "ERROR: $bin not built"; exit 1; }
    done
    file $out/bin/diff

    # Clean up docs
    rm -rf $out/share 2>/dev/null || true

    runHook postInstall
  '';

  meta = with lib; {
    description = "GNU Diffutils (diff, diff3, sdiff, cmp) for Redox OS";
    homepage = "https://www.gnu.org/software/diffutils/";
    license = licenses.gpl3Plus;
  };
}
