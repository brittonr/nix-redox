# sed - GNU sed stream editor for Redox OS
#
# GNU sed is the standard Unix stream editor. Essential for text processing
# in shell scripts and build systems.
#
# Patches from upstream Redox cookbook (sed 4.4):
# - mbcs.c: Disable mbrtowc (relibc doesn't implement it yet), force
#   is_mb_char to return 0 (treat everything as single-byte)
#
# Source: https://ftp.gnu.org/gnu/sed/sed-4.4.tar.xz
# Binary: sed

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
    url = "https://ftp.gnu.org/gnu/sed/sed-${version}.tar.xz";
    hash = "sha256-y9brxarwgO1g0BYtf2rq5YIRoe6bqbslYj2qbNlCaDs=";
  };

  extractedSrc = pkgs.stdenv.mkDerivation {
    name = "sed-${version}-src";
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
mkCLibrary.mkLibrary {
  pname = "sed";
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

    # Redox patch: mbcs.c — disable mbrtowc, return 0 for is_mb_char
    # relibc doesn't implement mbrtowc yet
    sed -i '/^is_mb_char.*mbstate_t/,/^{/ {
      /^{/a\  return 0; // FIXME: Implement mbrtowc in relibc, then remove this line
    }' sed/mbcs.c

    # Create doc stubs needed by automake
    mkdir -p doc
    touch doc/local.mk doc/sed.texi doc/sed.x doc/config.texi doc/version.texi doc/fdl.texi

    # autoreconf updates config.sub to recognize x86_64-unknown-redox
    autoreconf -fi

    ${mkCLibrary.crossEnvSetupWithWrapper}

    # Suppress errors that gnulib triggers with clang on Redox:
    # - incompatible-function-pointer-types in obstack.c (noreturn attr mismatch)
    # - deprecated isascii (relibc marks it deprecated)
    export CFLAGS="$CFLAGS -Wno-error=incompatible-function-pointer-types -Wno-error=deprecated-declarations"

    ./configure \
      --host=${redoxTarget} \
      --build=${pkgs.stdenv.buildPlatform.config} \
      --prefix=$out \
      --disable-nls

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    # Replace ONLY the gnulib headers causing circular include chains:
    # lib/stddef.h → relibc/stddef.h → lib/stdint.h → relibc/sys/types.h
    # → relibc/bits/pthread.h → needs size_t → still inside stddef.h!
    echo '#include_next <stddef.h>' > lib/stddef.h
    echo '#include_next <stdint.h>' > lib/stdint.h

    make -j $NIX_BUILD_CORES
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    make install

    # Verify
    test -f $out/bin/sed || { echo "ERROR: sed binary not built"; exit 1; }
    file $out/bin/sed

    # Clean up docs
    rm -rf $out/share 2>/dev/null || true

    runHook postInstall
  '';

  meta = with lib; {
    description = "GNU sed stream editor for Redox OS";
    homepage = "https://www.gnu.org/software/sed/";
    license = licenses.gpl3Plus;
  };
}
