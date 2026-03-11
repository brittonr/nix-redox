# gettext - GNU internationalization library for Redox OS
#
# We build ONLY libintl (the runtime library) — not the full GNU gettext
# tools. Most packages only need the libintl.h header and libintl.a
# for gettext()/ngettext() calls.
#
# Source: https://ftp.gnu.org/gnu/gettext/
# Output: libintl.a + headers + pkg-config

{
  pkgs,
  lib,
  redoxTarget,
  relibc,
  redox-libiconv,
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

  version = "0.22.5";

  src = pkgs.fetchurl {
    url = "https://ftp.gnu.org/gnu/gettext/gettext-${version}.tar.xz";
    hash = "sha256-/hDDc1MhPXiluD1IryMeAFxNqE21zogDfYg1WTgllkA=";
  };

  extractedSrc = pkgs.stdenv.mkDerivation {
    name = "gettext-${version}-src";
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

  sysroot = "${relibc}/${redoxTarget}";

in
mkCLibrary.mkLibrary {
  pname = "redox-gettext";
  inherit version;
  src = extractedSrc;
  buildInputs = [ redox-libiconv ];

  configurePhase = ''
    runHook preConfigure

    cp -r ${extractedSrc}/* .
    chmod -R u+w .

    ${mkCLibrary.crossEnvSetup}
    ${mkCLibrary.mkDepFlags [ redox-libiconv ]}

    # Build a minimal libintl by compiling only the core source files.
    # This avoids the entire gnulib portability layer that conflicts with relibc.
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    CC="${pkgs.llvmPackages.clang-unwrapped}/bin/clang"
    CFLAGS="--target=${redoxTarget} --sysroot=${sysroot} -I${sysroot}/include -D__redox__ -fPIC"

    # Redox is C-locale only, so libintl functions are simple passthroughs.
    # The real GNU gettext source has deep gnulib dependencies that don't
    # compile cleanly against relibc. Stub implementations are the standard
    # approach for single-locale systems.
    cat > libintl_stubs.c << 'STUBEOF'
    #include <stddef.h>

    /* Domain binding — no-ops that return their input */
    static const char *current_domain = "messages";

    char *libintl_textdomain(const char *domainname) {
        if (domainname) current_domain = domainname;
        return (char *)current_domain;
    }

    char *libintl_bindtextdomain(const char *domainname, const char *dirname) {
        (void)domainname;
        return (char *)dirname;
    }

    char *libintl_bind_textdomain_codeset(const char *domainname, const char *codeset) {
        (void)domainname;
        return (char *)codeset;
    }

    /* Message lookup — return msgid untranslated (C locale) */
    char *libintl_gettext(const char *msgid) {
        return (char *)msgid;
    }

    char *libintl_dgettext(const char *domainname, const char *msgid) {
        (void)domainname;
        return (char *)msgid;
    }

    char *libintl_dcgettext(const char *domainname, const char *msgid, int category) {
        (void)domainname;
        (void)category;
        return (char *)msgid;
    }

    /* Plural forms — return singular if n==1, plural otherwise */
    char *libintl_ngettext(const char *msgid, const char *msgid_plural, unsigned long n) {
        return (char *)(n == 1 ? msgid : msgid_plural);
    }

    char *libintl_dngettext(const char *domainname, const char *msgid, const char *msgid_plural, unsigned long n) {
        (void)domainname;
        return (char *)(n == 1 ? msgid : msgid_plural);
    }

    char *libintl_dcngettext(const char *domainname, const char *msgid, const char *msgid_plural, unsigned long n, int category) {
        (void)domainname;
        (void)category;
        return (char *)(n == 1 ? msgid : msgid_plural);
    }

    /* Needed by some consumers for locale charset detection */
    const char *locale_charset(void) {
        return "UTF-8";
    }
  STUBEOF

    echo "Compiling libintl stubs..."
    $CC $CFLAGS -c libintl_stubs.c -o libintl_stubs.o
    ${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-ar rcs libintl.a libintl_stubs.o
    ${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-ranlib libintl.a

    echo "=== libintl.a symbols ==="
    ${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-nm libintl.a | grep ' T '

    runHook postBuild
  '';

  installPhase = ''
        runHook preInstall

        mkdir -p $out/lib $out/include $out/lib/pkgconfig

        cp libintl.a $out/lib/

        # Generate libintl.h from the template in the extracted source
        template=$(find ${extractedSrc} -name 'libgnuintl.in.h' | head -1)
        if [ -n "$template" ]; then
          ${pkgs.python3}/bin/python3 -c "
    import re
    with open('$template') as f:
        content = f.read()
    subs = {
        'HAVE_VISIBILITY': '1',
        'HAVE_NEWLOCALE': '0',
        'HAVE_POSIX_PRINTF': '1',
        'HAVE_SNPRINTF': '1',
        'HAVE_ASPRINTF': '0',
        'HAVE_WPRINTF': '0',
        'ENHANCE_LOCALE_FUNCS': '0',
        'HAVE_NAMELESS_LOCALES': '0',
    }
    for k, v in subs.items():
        content = content.replace('@' + k + '@', v)
    content = re.sub(r'@[A-Z_]+@', '0', content)
    with open('$out/include/libintl.h', 'w') as f:
        f.write(content)
    "
        else
          echo "ERROR: libgnuintl.in.h template not found"; exit 1
        fi

        cat > $out/lib/pkgconfig/intl.pc << EOF
        prefix=$out
        libdir=\''${prefix}/lib
        includedir=\''${prefix}/include

        Name: intl
        Description: GNU internationalization library
        Version: ${version}
        Libs: -L\''${libdir} -lintl
        Cflags: -I\''${includedir}
  EOF

        test -f $out/lib/libintl.a || { echo "ERROR: libintl.a not built"; exit 1; }
        test -f $out/include/libintl.h || { echo "ERROR: libintl.h not generated"; exit 1; }
        echo "gettext (libintl) libraries:"
        ls -la $out/lib/lib*.a

        runHook postInstall
  '';

  meta = with lib; {
    description = "GNU internationalization library (libintl) for Redox OS";
    homepage = "https://www.gnu.org/software/gettext/";
    license = licenses.lgpl21Plus;
  };
}
