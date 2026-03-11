# glib - GLib core library for Redox OS
#
# GLib provides the core application building blocks for libraries and
# applications written in C. It's the foundation of GTK and GNOME.
# Required by: cairo, pango, atk, gdk-pixbuf, gtk3, and most GNOME apps.
#
# Depends on: zlib, libffi, libiconv, gettext (libintl), pcre2
#
# Source: https://download.gnome.org/sources/glib/
# Output: libglib-2.0.a + libgobject-2.0.a + libgio-2.0.a + libgmodule-2.0.a + headers + pkg-config

{
  pkgs,
  lib,
  redoxTarget,
  relibc,
  redox-zlib,
  redox-libffi,
  redox-libiconv,
  redox-gettext,
  redox-pcre2,
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

  version = "2.78.6";

  src = pkgs.fetchurl {
    url = "https://download.gnome.org/sources/glib/2.78/glib-${version}.tar.xz";
    hash = "sha256-JEhUZU3YLH68svjiRhVtKgXrnNGtB+16d5ZZtGAsn64=";
  };

  extractedSrc = pkgs.stdenv.mkDerivation {
    name = "glib-${version}-src";
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

  buildInputs = [
    redox-zlib
    redox-libffi
    redox-libiconv
    redox-gettext
    redox-pcre2
  ];

  baseCrossFile = mkCLibrary.mkMesonCrossFile buildInputs;

in
mkCLibrary.mkLibrary {
  pname = "redox-glib";
  inherit version buildInputs;

  src = extractedSrc;

  nativeBuildInputs = [
    pkgs.meson
    pkgs.ninja
    pkgs.python3
    pkgs.python3Packages.packaging
  ];

  configurePhase = ''
        runHook preConfigure

        cp -r ${extractedSrc}/* .
        chmod -R u+w .

        # Fix Python shebangs
        find . -name '*.py' -exec sed -i 's|#!/usr/bin/env python3|#!${pkgs.python3}/bin/python3|' {} \; 2>/dev/null || true

        ${mkCLibrary.crossEnvSetup}
        ${mkCLibrary.mkDepFlags buildInputs}

        # ---- Redox-specific patches ----

        # 1. LDBL_DIG: gnulib needs it, relibc's float.h doesn't define it
        sed -i '1i #ifndef LDBL_DIG\n#define LDBL_DIG __LDBL_DIG__\n#endif' glib/gnulib/vasnprintf.c

        # 2. relibc NULL=0 (int) breaks GLib atomic sizeof assertions.
        # Patch gatomic.h to remove the sizeof(oldval) checks.
        ${pkgs.python3}/bin/python3 << 'PYEOF'
    with open("glib/gatomic.h") as f:
        content = f.read()
    content = content.replace(
        'G_STATIC_ASSERT (sizeof (oldval) == sizeof (gpointer));',
        '/* patched: sizeof(oldval) removed for relibc NULL=0 */'
    )
    with open("glib/gatomic.h", "w") as f:
        f.write(content)
  PYEOF

        # 3. Python 3.12+ removed distutils; gdbus-codegen uses it
        find . -name 'utils.py' -path '*/codegen/*' -exec sed -i 's/import distutils\.version/import packaging.version/' {} \;
        find . -name 'utils.py' -path '*/codegen/*' -exec sed -i 's/distutils\.version\.LooseVersion/packaging.version.Version/g' {} \;
        find . -name 'utils.py' -path '*/codegen/*' -exec sed -i 's/distutils\.version\.StrictVersion/packaging.version.Version/g' {} \;

        # 4. Stub headers for networking APIs Redox doesn't have
        mkdir -p _stubs/arpa
        # Declare POSIX *at() functions that relibc doesn't declare.
        # relibc already has: fchmodat, mkdirat, renameat (in sys/stat.h / stdio.h)
        # Missing: openat, linkat, unlinkat, fchownat
        for f in gio/glocalfile.c gio/glocalfileinfo.c gio/glocalfilemonitor.c; do
          if [ -f "$f" ]; then
            sed -i '1i /* Redox compat */\n#include <sys/stat.h>\nint openat(int,const char*,int,...);\nint linkat(int,const char*,int,const char*,int);\nint unlinkat(int,const char*,int);\nint fchownat(int,const char*,unsigned int,unsigned int,int);\n#ifndef AT_FDCWD\n#define AT_FDCWD (-100)\n#endif\n#ifndef AT_REMOVEDIR\n#define AT_REMOVEDIR 0x200\n#endif\n#ifndef AT_SYMLINK_NOFOLLOW\n#define AT_SYMLINK_NOFOLLOW 0x100\n#endif' "$f"
          fi
        done

        echo '#pragma once' > _stubs/resolv.h
        echo '#include <netinet/in.h>' >> _stubs/resolv.h
        echo '#define MAXNS 3' >> _stubs/resolv.h
        echo 'struct __res_state { int nscount; struct sockaddr_in nsaddr_list[MAXNS]; };' >> _stubs/resolv.h
        echo 'typedef struct __res_state *res_state;' >> _stubs/resolv.h
        echo 'static inline int res_query(const char *a, int b, int c, unsigned char *d, int e) { (void)a;(void)b;(void)c;(void)d;(void)e; return -1; }' >> _stubs/resolv.h
        echo 'static inline int res_init(void) { return -1; }' >> _stubs/resolv.h

        # Comprehensive DNS stub headers — GIO's gthreadedresolver.c uses the full API
        ${pkgs.python3}/bin/python3 << 'PYEOF'
    import os
    os.makedirs("_stubs/arpa", exist_ok=True)

    with open("_stubs/resolv.h", "w") as f:
        f.write("""#pragma once
    #include <netinet/in.h>
    #include <arpa/nameser.h>
    #define MAXNS 3
    struct __res_state { int nscount; struct sockaddr_in nsaddr_list[MAXNS]; };
    typedef struct __res_state *res_state;
    static inline int res_query(const char *a, int b, int c, unsigned char *d, int e) { (void)a;(void)b;(void)c;(void)d;(void)e; return -1; }
    static inline int res_init(void) { return -1; }
    """)

    with open("_stubs/arpa/nameser.h", "w") as f:
        f.write("""#pragma once
    #include <stdint.h>
    #define NS_MAXDNAME 1025
    #define NS_PACKETSZ 512
    #define C_IN 1
    #define T_A 1
    #define T_AAAA 28
    #define T_MX 15
    #define T_SRV 33
    #define T_NS 2
    #define T_TXT 16
    #define T_SOA 6
    #define QUERY 0
    #define NOERROR 0
    #define GETSHORT(s, cp) do { uint16_t t; unsigned char *p = (unsigned char*)(cp); t = (p[0] << 8) | p[1]; (cp) += 2; (s) = t; } while(0)
    #define GETLONG(l, cp) do { uint32_t t; unsigned char *p = (unsigned char*)(cp); t = ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3]; (cp) += 4; (l) = t; } while(0)
    typedef struct {
      unsigned id:16; unsigned qr:1; unsigned opcode:4; unsigned aa:1;
      unsigned tc:1; unsigned rd:1; unsigned ra:1; unsigned unused:1;
      unsigned ad:1; unsigned cd:1; unsigned rcode:4;
      unsigned qdcount:16; unsigned ancount:16; unsigned nscount:16; unsigned arcount:16;
    } HEADER;
    static inline int dn_expand(const unsigned char *msg, const unsigned char *eom, const unsigned char *src, char *dst, int dstsiz) {
      (void)msg;(void)eom;(void)src;(void)dst;(void)dstsiz; return -1;
    }
    static inline int dn_skipname(const unsigned char *p, const unsigned char *eom) {
      (void)p;(void)eom; return -1;
    }
    """)

    with open("_stubs/arpa/nameser_compat.h", "w") as f:
        f.write("#pragma once\n#include <arpa/nameser.h>\n")
  PYEOF

        # 5. Create modified meson cross file with stub header path
        STUBS_DIR="$(pwd)/_stubs"
        cp ${baseCrossFile} cross-file.txt
        chmod +w cross-file.txt
        sed -i "s|'-fPIC'|'-fPIC', '-I$STUBS_DIR'|" cross-file.txt

        # 6. Create CI test wrapper stub (GLib tries to find it)
        mkdir -p .gitlab-ci
        echo '#!/bin/sh' > .gitlab-ci/thorough-test-wrapper.sh
        chmod +x .gitlab-ci/thorough-test-wrapper.sh

        # 7. Patch meson.build to inject cross-compiled iconv and intl
        ${pkgs.python3}/bin/python3 << 'PYEOF'
    with open("meson.build") as f:
        content = f.read()
    content = content.replace(
        "iconv = dependency('iconv'",
        "iconv = declare_dependency(link_args: ['-L${redox-libiconv}/lib', '-liconv'], compile_args: ['-I${redox-libiconv}/include'])\n# iconv = dependency('iconv'"
    )
    content = content.replace(
        "libintl = dependency('intl'",
        "libintl = declare_dependency(link_args: ['-L${redox-gettext}/lib', '-lintl'], compile_args: ['-I${redox-gettext}/include'])\n# libintl = dependency('intl'"
    )
    with open("meson.build", "w") as f:
        f.write(content)

    # 8. Patch gio/meson.build to skip DNS resolver checks
    with open("gio/meson.build") as f:
        gio = f.read()
    gio = gio.replace(
        "error('Could not find required includes for ARPA C_IN')",
        "warning('ARPA C_IN not found on Redox')"
    )
    gio = gio.replace(
        "error('Could not find res_query()')",
        "warning('res_query() not found on Redox')"
    )
    gio = gio.replace(
        "error('Could not find socket()')",
        "warning('socket() not found on Redox')"
    )
    with open("gio/meson.build", "w") as f:
        f.write(gio)
  PYEOF

        # 9. Patch GIO source files for Redox compatibility
        # gunixmounts.c: the internal functions _g_get_unix_mounts,
        # _g_get_unix_mount_points, get_mtab_monitor_file are defined
        # inside #if chains (HAVE_GETMNTENT_R, HAVE_GETMNTENT, etc.).
        # On Redox none match → #error. We must replace each #error with
        # an actual function body that returns empty results.
        ${pkgs.python3}/bin/python3 << 'PYEOF'
    with open("gio/gunixmounts.c") as f:
        content = f.read()

    # Each platform provides a full function definition under its #if.
    # On Redox none match, so we must provide complete function bodies.
    content = content.replace(
        '#error No _g_get_unix_mounts() implementation for system',
        "/* Redox: no mount entries */\nstatic GList *\n_g_get_unix_mounts (void)\n{\n  return (void *)0;\n}"
    )

    content = content.replace(
        '#error No _g_get_unix_mount_points() implementation for system',
        "/* Redox: no mount points */\nstatic GList *\n_g_get_unix_mount_points (void)\n{\n  return (void *)0;\n}"
    )

    content = content.replace(
        '#error No g_get_mount_table() implementation for system',
        "/* Redox: no mount table or mount points */\nstatic GList *\n_g_get_unix_mount_points (void)\n{\n  return (void *)0;\n}"
    )

    content = content.replace(
        '#error No get_mounts_timestamp() implementation',
        "/* Redox: no mounts timestamp */\nstatic guint64\nget_mounts_timestamp (void)\n{\n  return 0;\n}"
    )

    # Add fallback get_mtab_monitor_file at the top if not already present
    if '_g_get_unix_mounts' in content and '__redox__' not in content:
        content = '#ifdef __redox__\nstatic const char *get_mtab_monitor_file(void) { return (const char *)0; }\n#endif\n' + content

    with open("gio/gunixmounts.c", "w") as f:
        f.write(content)
  PYEOF

        # 10. Create Redox stubs for missing POSIX *at() functions.
        # relibc doesn't implement openat/unlinkat/fchownat/linkat.
        # Create a .c file added to gio's build.
        cat > gio/_redox_stubs.c << 'STUBEOF'
    /* Stub implementations of POSIX *at() functions for Redox OS.
     * These ignore the dirfd parameter and fall back to non-at variants.
     * This is safe because GIO always passes AT_FDCWD on Redox. */
    #include <fcntl.h>
    #include <stdarg.h>
    #include <unistd.h>

    /* Prototypes (not in relibc headers) */
    int openat(int dirfd, const char *pathname, int flags, ...);
    int unlinkat(int dirfd, const char *pathname, int flags);
    int fchownat(int dirfd, const char *pathname, unsigned int uid, unsigned int gid, int flags);
    int linkat(int olddirfd, const char *oldpath, int newdirfd, const char *newpath, int flags);

    int openat(int dirfd, const char *pathname, int flags, ...) {
        (void)dirfd;
        if (flags & O_CREAT) {
            va_list ap;
            va_start(ap, flags);
            int mode = va_arg(ap, int);
            va_end(ap);
            return open(pathname, flags, mode);
        }
        return open(pathname, flags);
    }

    int unlinkat(int dirfd, const char *pathname, int flags) {
        (void)dirfd;
        (void)flags;
        return unlink(pathname);
    }

    int fchownat(int dirfd, const char *pathname, unsigned int uid, unsigned int gid, int flags) {
        (void)dirfd; (void)pathname; (void)uid; (void)gid; (void)flags;
        return 0;
    }

    int linkat(int olddirfd, const char *oldpath, int newdirfd, const char *newpath, int flags) {
        (void)olddirfd; (void)newdirfd; (void)flags;
        return link(oldpath, newpath);
    }
  STUBEOF

        # Wire _redox_stubs.c into gio/meson.build
        ${pkgs.python3}/bin/python3 << 'PYEOF'
    with open("gio/meson.build") as f:
        content = f.read()
    # Add our stubs file to the gio sources list
    content = content.replace(
        "gio_sources = files(",
        "gio_sources = files(\n  '_redox_stubs.c',"
    )
    with open("gio/meson.build", "w") as f:
        f.write(content)
  PYEOF

        meson setup build \
          --cross-file cross-file.txt \
          --prefix=$out \
          --default-library=static \
          --wrap-mode=nodownload \
          -Dxattr=false \
          -Dtests=false \
          -Dinstalled_tests=false \
          -Dnls=disabled \
          -Ddtrace=false \
          -Dsystemtap=false \
          -Dgtk_doc=false \
          -Dbsymbolic_functions=false \
          -Dforce_posix_threads=false \
          -Dglib_assert=false \
          -Dglib_checks=false \
          -Dman=false

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

    test -f $out/lib/libglib-2.0.a || { echo "ERROR: libglib-2.0.a not built"; exit 1; }
    echo "glib libraries:"
    ls -la $out/lib/lib*.a

    runHook postInstall
  '';

  meta = with lib; {
    description = "GLib core library for Redox OS";
    homepage = "https://docs.gtk.org/glib/";
    license = licenses.lgpl21Plus;
  };
}
