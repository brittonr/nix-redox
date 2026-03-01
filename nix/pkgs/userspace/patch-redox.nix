# patch - GNU patch for Redox OS
#
# GNU patch applies diff files to originals. Essential for development
# workflows and source patching.
#
# Patches from upstream Redox cookbook (patch 2.7.6):
# - getdtablesize.c + safe.c: Remove RLIMIT_NOFILE usage (not on Redox)
# - util.c: Disable lchown calls (not fully supported on Redox)
# - renameat2.c: Disable renameat2 on Redox (not available)
#
# Source: https://ftp.gnu.org/gnu/patch/patch-2.7.6.tar.xz
# Binary: patch

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

  version = "2.7.6";

  src = pkgs.fetchurl {
    url = "https://ftp.gnu.org/gnu/patch/patch-${version}.tar.xz";
    hash = "sha256-rGEL2per4Nn2t8ljJVoR3LGWwl4zfGH5Tkd41jLx2P0=";
  };

  extractedSrc = pkgs.stdenv.mkDerivation {
    name = "patch-${version}-src";
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

  # Python patching script
  patchScript = pkgs.writeText "patch-redox-patch.py" ''
    import os

    def patch_file(path, old, new):
        with open(path) as f:
            content = f.read()
        patched = content.replace(old, new, 1)
        if patched == content:
            print(f"WARNING: patch not applied to {path} (pattern not found)")
        with open(path, "w") as f:
            f.write(patched)

    # 1. getdtablesize.c: remove RLIMIT_NOFILE usage
    patch_file("lib/getdtablesize.c",
        "int\ngetdtablesize (void)\n{\n  struct rlimit lim;\n\n"
        "  if (getrlimit (RLIMIT_NOFILE, &lim) == 0\n"
        "      && 0 <= lim.rlim_cur && lim.rlim_cur <= INT_MAX\n"
        "      && lim.rlim_cur != RLIM_INFINITY\n"
        "      && lim.rlim_cur != RLIM_SAVED_CUR\n"
        "      && lim.rlim_cur != RLIM_SAVED_MAX)\n"
        "    return lim.rlim_cur;\n\n  return INT_MAX;\n}",
        "int\ngetdtablesize (void)\n{\n  return INT_MAX;\n}")

    # 2. safe.c: remove RLIMIT_NOFILE in init_dirfd_cache
    patch_file("src/safe.c",
        "static void init_dirfd_cache (void)\n{\n"
        "  struct rlimit nofile;\n\n  max_cached_fds = 8;\n"
        "  if (getrlimit (RLIMIT_NOFILE, &nofile) == 0)\n"
        "    max_cached_fds = MAX (nofile.rlim_cur / 4, max_cached_fds);",
        "static void init_dirfd_cache (void)\n{\n  max_cached_fds = 8;")

    # 3. util.c: disable lchown calls (comment out entire if block)
    with open("src/util.c") as f:
        content = f.read()
    # Comment out the entire lchown block
    content = content.replace(
        "      if ((uid != -1 || gid != -1)\n"
        "\t  && safe_lchown (to, uid, gid) != 0\n"
        "\t  && (errno != EPERM\n"
        "\t      || (uid != -1\n"
        "\t\t  && safe_lchown (to, (uid = -1), gid) != 0\n"
        "\t\t  && errno != EPERM)))\n"
        "\tpfatal (\"Failed to set the %s of %s %s\",\n"
        "\t\t(uid == -1) ? \"owner\" : \"owning group\",\n"
        "\t\tS_ISLNK (mode) ? \"symbolic link\" : \"file\",\n"
        "\t\tquotearg (to));",
        "      /* lchown disabled on Redox */\n"
        "      (void)uid; (void)gid;", 1)
    with open("src/util.c", "w") as f:
        f.write(content)

    # 4. renameat2.c: disable on Redox
    patch_file("lib/renameat2.c",
        "int\nrenameat2 (int fd1, char const *src, int fd2, char const *dst,\n"
        "           unsigned int flags)",
        "#if !defined(__redox__)\nint\nrenameat2 (int fd1, char const *src, int fd2, char const *dst,\n"
        "           unsigned int flags)")
    with open("lib/renameat2.c") as f:
        content = f.read()
    content = content.rstrip() + "\n#endif\n"
    with open("lib/renameat2.c", "w") as f:
        f.write(content)

    print("All patch-redox patches applied successfully")
  '';

in
mkCLibrary.mkLibrary {
  pname = "patch";
  inherit version;
  src = extractedSrc;

  configurePhase = ''
        runHook preConfigure

        cp -r ${extractedSrc}/* .
        chmod -R u+w .

        # Apply Redox patches
        ${pkgs.python3}/bin/python3 ${patchScript}

        # Update config.sub to recognize x86_64-unknown-redox (no full autoreconf)
        cp ${pkgs.gnu-config}/config.sub build-aux/config.sub
        cp ${pkgs.gnu-config}/config.guess build-aux/config.guess

        # Fix timestamps to prevent autotools regeneration
        find . -type f -exec touch -t 202501010000 {} +
        touch aclocal.m4
        sleep 1
        touch configure
        sleep 1
        find . -name 'config.h.in' -exec touch {} \;
        sleep 1
        find . -name 'Makefile.in' -exec touch {} \;

        ${mkCLibrary.crossEnvSetupWithWrapper}

        # Suppress clang/gnulib warnings and errors for missing Redox APIs
        export CFLAGS="$CFLAGS -Wno-error -Wno-implicit-function-declaration -Wno-incompatible-function-pointer-types -Wno-deprecated-declarations -DAT_EACCESS=0x200 -DO_SEARCH=O_RDONLY -DLDBL_DIG=__LDBL_DIG__"

        ./configure \
          --host=${redoxTarget} \
          --build=${pkgs.stdenv.buildPlatform.config} \
          --prefix=$out \
          gl_cv_func_working_mktime=yes \
          gl_cv_func_tzset_clobber=no

        # Replace ONLY the gnulib headers causing circular include chains
        echo '#include_next <stddef.h>' > lib/stddef.h
        echo '#include_next <stdint.h>' > lib/stdint.h

        # Replace gnulib's time_rz.c with stubs (relibc lacks timezone support).
        # The real time_rz.c uses internal structs that don't exist on Redox.
        cat > lib/time_rz.c << 'TIMERZEOF'
    #include <config.h>
    #include <time.h>
    #include <stdlib.h>
    typedef void *timezone_t;
    timezone_t tzalloc(const char *name) { (void)name; return NULL; }
    void tzfree(timezone_t tz) { (void)tz; }
    struct tm *localtime_rz(timezone_t tz, const time_t *tp, struct tm *result) { (void)tz; return localtime_r(tp, result); }
    time_t mktime_z(timezone_t tz, struct tm *tmp) { (void)tz; return mktime(tmp); }
    TIMERZEOF

        # Also create lib/time.h with timezone_t typedef (for headers that need it)
        cat > lib/time.h << 'TIMEH'
    #include_next <time.h>
    #ifndef _REDOX_TZ_STUB
    #define _REDOX_TZ_STUB
    typedef void *timezone_t;
    timezone_t tzalloc(const char *name);
    void tzfree(timezone_t tz);
    struct tm *localtime_rz(timezone_t tz, const time_t *tp, struct tm *result);
    time_t mktime_z(timezone_t tz, struct tm *tmp);
    #endif
    TIMEH

        runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make -j $NIX_BUILD_CORES \
      AUTOCONF=true AUTOHEADER=true AUTOMAKE=true ACLOCAL=true
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    make install \
      AUTOCONF=true AUTOHEADER=true AUTOMAKE=true ACLOCAL=true

    # Verify
    test -f $out/bin/patch || { echo "ERROR: patch binary not built"; exit 1; }
    file $out/bin/patch

    # Clean up docs
    rm -rf $out/share $out/lib 2>/dev/null || true

    runHook postInstall
  '';

  meta = with lib; {
    description = "GNU patch for Redox OS";
    homepage = "https://www.gnu.org/software/patch/";
    license = licenses.gpl3Plus;
  };
}
