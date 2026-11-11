# tree - recursive directory listing for Redox OS
#
# Small C utility used to validate the C cross-build path and give the
# development image a familiar directory browser.
#
# Source: https://github.com/Old-Man-Programmer/tree
# Binary: tree

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

  version = "2.2.1";

  src = pkgs.fetchurl {
    url = "https://github.com/Old-Man-Programmer/tree/archive/refs/tags/${version}.tar.gz";
    hash = "sha256-XK3cvKgFEx/1kLEm0yGAGYguTKELyetJC7pRwFubO3U=";
  };

in
mkCLibrary.mkLibrary {
  pname = "redox-tree";
  inherit version src;

  nativeBuildInputs = [
    pkgs.gnutar
    pkgs.gzip
  ];

  configurePhase = ''
    runHook preConfigure

    mkdir source
    tar xf ${src} -C source --strip-components=1
    cd source
    chmod -R u+w .

    ${mkCLibrary.crossEnvSetupWithWrapper}

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    make -j"$NIX_BUILD_CORES" tree \
      CC="$CC" \
      CFLAGS="$CFLAGS -std=c11" \
      CPPFLAGS="$CPPFLAGS" \
      LDFLAGS="$LDFLAGS"

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp tree $out/bin/tree
    chmod 755 $out/bin/tree
    test -x $out/bin/tree

    runHook postInstall
  '';

  meta = with lib; {
    description = "Recursive directory listing utility for Redox OS";
    homepage = "https://oldmanprogrammer.net/source.php?url=/about.php";
    license = licenses.gpl2Plus;
    mainProgram = "tree";
  };
}
