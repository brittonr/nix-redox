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

    cd gettext-runtime/intl

    CC="${pkgs.llvmPackages.clang-unwrapped}/bin/clang"

    INTL_CFLAGS="--target=${redoxTarget} --sysroot=${sysroot} -I${sysroot}/include"
    INTL_CFLAGS="$INTL_CFLAGS -I. -I.. -I${redox-libiconv}/include"
    INTL_CFLAGS="$INTL_CFLAGS -D__redox__ -DHAVE_CONFIG_H -DLOCALEDIR=\"/usr/share/locale\""
    INTL_CFLAGS="$INTL_CFLAGS -DLOCALE_ALIAS_PATH=\"/usr/share/locale\""
    INTL_CFLAGS="$INTL_CFLAGS -DLIBDIR=\"/usr/lib\" -DIN_LIBINTL"
    INTL_CFLAGS="$INTL_CFLAGS -DENABLE_RELOCATABLE=0 -DNO_XMALLOC"
    INTL_CFLAGS="$INTL_CFLAGS -fPIC -Wno-incompatible-pointer-types"

    # Create a minimal config.h
    cat > config.h << 'CONFEOF'
    #define HAVE_ALLOCA_H 1
    #define HAVE_ALLOCA 1
    #define HAVE_STDLIB_H 1
    #define HAVE_STRING_H 1
    #define HAVE_MEMORY_H 1
    #define HAVE_STRINGS_H 1
    #define HAVE_UNISTD_H 1
    #define HAVE_STDINT_H 1
    #define HAVE_LIMITS_H 1
    #define HAVE_LOCALE_H 1
    #define HAVE_GETCWD 1
    #define HAVE_STPCPY 1
    #define HAVE_MEMPCPY 1
    #define HAVE_TSEARCH 1
    #define HAVE_ICONV 1
    #define HAVE_SETLOCALE 1
    #define HAVE_NEWLOCALE 0
    #define HAVE_USELOCALE 0
    #define STDC_HEADERS 1
    #define ENABLE_NLS 1
    CONFEOF

    # Compile the minimal set of libintl source files
    OBJS=""
    for src_file in \
      bindtextdom.c dcgettext.c dgettext.c gettext.c \
      finddomain.c hash-string.c loadmsgcat.c localealias.c \
      textdomain.c l10nflist.c explodename.c dcigettext.c \
      dcngettext.c dngettext.c ngettext.c plural.c plural-exp.c \
      localcharset.c log.c printf.c osdep.c intl-compat.c; do
      if [ -f "$src_file" ]; then
        obj=$(basename $src_file .c).o
        echo "Compiling $src_file..."
        $CC $INTL_CFLAGS -c "$src_file" -o "$obj" 2>/dev/null && OBJS="$OBJS $obj" || echo "  skipped $src_file"
      fi
    done

    # Archive into static library
    ${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-ar rcs libintl.a $OBJS
    ${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-ranlib libintl.a

    runHook postBuild
  '';

  installPhase = ''
        runHook preInstall

        mkdir -p $out/lib $out/include $out/lib/pkgconfig

        cp libintl.a $out/lib/
        cp libintl.h $out/include/ 2>/dev/null || cp ../../gettext-runtime/intl/libintl.h $out/include/ 2>/dev/null || true

        # Generate libintl.h from libgnuintl.in.h template using Python
        if [ ! -f "$out/include/libintl.h" ]; then
          template=$(find ../.. -name 'libgnuintl.in.h' | head -1)
          if [ -n "$template" ]; then
            ${pkgs.python3}/bin/python3 -c "
    import re, sys
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
    # Replace any remaining @VAR@ with 0 (safe default for #if)
    import re
    content = re.sub(r'@[A-Z_]+@', '0', content)
    with open('$out/include/libintl.h', 'w') as f:
        f.write(content)
    "
          fi
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
