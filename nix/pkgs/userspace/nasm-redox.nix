# nasm - Netwide Assembler for Redox OS
#
# Cross-compiles NASM (same version/source as host pkgs.nasm) to
# x86_64-unknown-redox so the guest can assemble kernel trampolines
# byte-identically to host builds.
#
# Binaries: nasm, ndisasm

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

  version = pkgs.nasm.version;

  patchedSrc = pkgs.applyPatches {
    name = "nasm-${version}-src";
    src = pkgs.nasm.src;
    patches = pkgs.nasm.patches or [ ];
  };

in
mkCLibrary.mkLibrary {
  pname = "redox-nasm";
  inherit version;
  src = patchedSrc;

  nativeBuildInputs = [
    pkgs.perl
  ];

  configurePhase = ''
    runHook preConfigure

    cp -r ${patchedSrc}/. .
    chmod -R u+w .

    ${mkCLibrary.crossEnvSetupWithWrapper}

    # Update config.sub if needed so x86_64-unknown-redox is recognized.
    if [ -f autoconf/helpers/config.sub ] && ! ./autoconf/helpers/config.sub ${redoxTarget} >/dev/null 2>&1; then
      cp ${pkgs.gnu-config}/config.sub autoconf/helpers/config.sub
      cp ${pkgs.gnu-config}/config.guess autoconf/helpers/config.guess
      chmod +x autoconf/helpers/config.sub autoconf/helpers/config.guess
    fi

    ./configure \
      --host=${redoxTarget} \
      --build=${pkgs.stdenv.buildPlatform.config} \
      --prefix=$out

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make -j $NIX_BUILD_CORES nasm ndisasm
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp nasm $out/bin/nasm
    cp ndisasm $out/bin/ndisasm
    chmod 755 $out/bin/nasm $out/bin/ndisasm

    test -f $out/bin/nasm || { echo "ERROR: nasm binary not built"; exit 1; }
    file $out/bin/nasm

    runHook postInstall
  '';

  meta = with lib; {
    description = "Netwide Assembler (NASM) for Redox OS";
    homepage = "https://www.nasm.us/";
    license = licenses.bsd2;
    mainProgram = "nasm";
  };
}
