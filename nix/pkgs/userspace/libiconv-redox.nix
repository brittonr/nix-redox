# libiconv - Character set conversion library for Redox OS
#
# GNU libiconv provides iconv() for character encoding conversion.
# Required by gettext, glib, and many C applications that handle
# internationalized text.
#
# Source: https://ftp.gnu.org/gnu/libiconv/
# Output: libiconv.a + libcharset.a + headers + pkg-config

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

  version = "1.17";

  src = pkgs.fetchurl {
    url = "https://ftp.gnu.org/gnu/libiconv/libiconv-${version}.tar.gz";
    hash = "sha256-j3QhO1YjjIWlClMp934GGYdx5w3Zpzl3n0wC9l2XExM=";
  };

  extractedSrc = pkgs.stdenv.mkDerivation {
    name = "libiconv-${version}-src";
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
  pname = "redox-libiconv";
  inherit version;
  src = extractedSrc;

  nativeBuildInputs = [ pkgs.gnu-config ];

  configurePhase = ''
    runHook preConfigure

    cp -r ${extractedSrc}/* .
    chmod -R u+w .

    # Use the CC wrapper so configure link tests can find CRT files
    ${mkCLibrary.crossEnvSetupWithWrapper}

    # Update config.sub/config.guess for Redox target
    find . -name config.sub -exec chmod +w {} \; -exec cp ${pkgs.gnu-config}/config.sub {} \;
    find . -name config.guess -exec chmod +w {} \; -exec cp ${pkgs.gnu-config}/config.guess {} \;

    # Create stub man/Makefile.in (configure expects it)
    mkdir -p man
    cat > man/Makefile.in << 'MANMK'
    all:
    install:
  MANMK

    # Prevent autotools regeneration
    find . -name configure -exec touch {} +
    find . -name '*.in' -exec touch {} +

    ./configure \
      --host=${redoxTarget} \
      --build=${pkgs.stdenv.buildPlatform.config} \
      --prefix=$out \
      --enable-static \
      --disable-shared \
      --disable-nls

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    # Patch include/iconv.h to include stddef.h for wchar_t
    find . -name 'iconv.h' -exec grep -l 'wchar_t' {} \; | while read f; do
      if ! grep -q '#include <stddef.h>' "$f"; then
        sed -i '1i #include <stddef.h>' "$f"
      fi
    done

    # Build libcharset first (lib/ depends on it), then lib/.
    # Skip srclib/ (gnulib portability layer with POSIX functions not in relibc).
    make -C libcharset -j $NIX_BUILD_CORES

    # lib/ needs localcharset.h from libcharset/include.
    # Must patch the Makefile since libtool ignores env CFLAGS.
    sed -i "s|^CFLAGS = |CFLAGS = -I$(pwd)/libcharset/include |" lib/Makefile
    make -C lib -j $NIX_BUILD_CORES
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib $out/include $out/lib/pkgconfig

    # Install the core library
    cp lib/.libs/libiconv.a $out/lib/ 2>/dev/null || cp lib/libiconv.a $out/lib/
    cp libcharset/lib/.libs/libcharset.a $out/lib/ 2>/dev/null || true

    # Install headers
    cp include/iconv.h $out/include/
    cp libcharset/include/localcharset.h $out/include/ 2>/dev/null || true
    if [ -f libcharset/include/libcharset.h ]; then
      cp libcharset/include/libcharset.h $out/include/
    fi

    # Patch installed iconv.h too
    if ! grep -q '#include <stddef.h>' "$out/include/iconv.h"; then
      sed -i '1i #include <stddef.h>' "$out/include/iconv.h"
    fi

    # Generate pkg-config
    cat > $out/lib/pkgconfig/iconv.pc << EOF
    prefix=$out
    libdir=\''${prefix}/lib
    includedir=\''${prefix}/include

    Name: iconv
    Description: GNU character set conversion library
    Version: ${version}
    Libs: -L\''${libdir} -liconv
    Cflags: -I\''${includedir}
  EOF

    # Verify
    test -f $out/lib/libiconv.a || { echo "ERROR: libiconv.a not built"; exit 1; }
    echo "libiconv libraries:"
    ls -la $out/lib/lib*.a
    runHook postInstall
  '';

  meta = with lib; {
    description = "Character set conversion library for Redox OS";
    homepage = "https://www.gnu.org/software/libiconv/";
    license = licenses.lgpl2Plus;
  };
}
