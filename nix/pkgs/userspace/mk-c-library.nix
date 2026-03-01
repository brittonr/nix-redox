# C library cross-compilation builder for Redox OS
#
# This module provides helpers for building C libraries (autotools, cmake,
# meson, or plain Makefile) cross-compiled to the Redox target.
#
# Uses clang as the cross-compiler with relibc as the sysroot.
# Produces static libraries (.a) and headers for use by other packages.
#
# Usage:
#   mkCLibrary = import ./mk-c-library.nix { ... };
#
#   zlib = mkCLibrary.mkAutotools {
#     pname = "zlib";
#     version = "1.3";
#     src = fetchurl { ... };
#     configureFlags = [ "--static" "--prefix=/usr" ];
#   };

{
  pkgs,
  lib,
  redoxTarget,
  relibc,
  ...
}:

let
  # Decompose target triple
  targetArch = builtins.head (lib.splitString "-" redoxTarget);

  # Cross-compiler paths
  cc = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang";
  cxx = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang++";
  ar = "${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-ar";
  ranlib = "${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-ranlib";
  strip = "${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-strip";
  ld = "${pkgs.llvmPackages.lld}/bin/ld.lld";
  nm = "${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-nm";

  sysroot = "${relibc}/${redoxTarget}";

  # Common cross-compilation flags
  baseCFlags = builtins.concatStringsSep " " [
    "--target=${redoxTarget}"
    "--sysroot=${sysroot}"
    "-D__redox__"
    "-U_FORTIFY_SOURCE"
    "-D_FORTIFY_SOURCE=0"
    "-I${sysroot}/include"
    "-fPIC"
  ];

  baseLdFlags = builtins.concatStringsSep " " [
    "--target=${redoxTarget}"
    "--sysroot=${sysroot}"
    "-L${sysroot}/lib"
    "-static"
    "-nostdlib"
  ];

  # Common native build inputs (host tools)
  commonNativeBuildInputs = with pkgs; [
    llvmPackages.clang
    llvmPackages.bintools
    llvmPackages.lld
    gnumake
    pkg-config
  ];

  # Shell snippet that exports all cross-compilation environment variables
  crossEnvSetup = ''
    export CC="${cc}"
    export CXX="${cxx}"
    export AR="${ar}"
    export RANLIB="${ranlib}"
    export STRIP="${strip}"
    export LD="${ld}"
    export NM="${nm}"

    export CHOST="${redoxTarget}"
    export TARGET="${redoxTarget}"

    export CFLAGS="${baseCFlags}"
    export CXXFLAGS="${baseCFlags}"
    export CPPFLAGS="-I${sysroot}/include"
    export LDFLAGS="${baseLdFlags}"

    # For pkg-config to find cross-compiled libraries
    export PKG_CONFIG_LIBDIR="$out/lib/pkgconfig:${sysroot}/lib/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="${sysroot}"
  '';

  # Helper to add dependency paths to CFLAGS/LDFLAGS
  mkDepFlags =
    deps:
    let
      cflags = lib.concatMapStringsSep " " (d: "-I${d}/include") deps;
      ldflags = lib.concatMapStringsSep " " (d: "-L${d}/lib") deps;
    in
    ''
      export CFLAGS="$CFLAGS ${cflags}"
      export CXXFLAGS="$CXXFLAGS ${cflags}"
      export CPPFLAGS="$CPPFLAGS ${cflags}"
      export LDFLAGS="$LDFLAGS ${ldflags}"
      export PKG_CONFIG_LIBDIR="$PKG_CONFIG_LIBDIR${lib.concatMapStrings (d: ":${d}/lib/pkgconfig") deps}"
    '';

in
rec {
  inherit crossEnvSetup mkDepFlags;

  # Build a C library using a custom build script
  mkLibrary =
    {
      pname,
      version ? "unstable",
      src,
      nativeBuildInputs ? [ ],
      buildInputs ? [ ], # Cross-compiled Redox library dependencies
      preConfigure ? "",
      configurePhase ? null,
      buildPhase ? null,
      installPhase,
      postInstall ? "",
      meta ? { },
    }:
    pkgs.stdenv.mkDerivation {
      inherit pname version;

      dontUnpack = true;
      dontFixup = true; # Don't run patchelf etc. on cross-compiled output

      nativeBuildInputs = commonNativeBuildInputs ++ nativeBuildInputs;

      configurePhase =
        if configurePhase != null then
          configurePhase
        else
          ''
            runHook preConfigure

            # Copy source with write permissions
            cp -r ${src}/* . 2>/dev/null || cp -r ${src} source && cd source
            chmod -R u+w .

            ${crossEnvSetup}
            ${mkDepFlags buildInputs}
            ${preConfigure}

            runHook postConfigure
          '';

      buildPhase =
        if buildPhase != null then
          buildPhase
        else
          ''
            runHook preBuild
            make -j $NIX_BUILD_CORES
            runHook postBuild
          '';

      inherit installPhase;

      postInstall = ''
        ${postInstall}

        # Clean up files not needed for cross-compilation
        rm -rf $out/share/man $out/share/doc $out/share/info 2>/dev/null || true
      '';

      inherit meta;
    };

  # Build a C library using autotools (./configure && make && make install)
  mkAutotools =
    {
      pname,
      version ? "unstable",
      src,
      nativeBuildInputs ? [ ],
      buildInputs ? [ ],
      configureFlags ? [ ],
      preConfigure ? "",
      preBuild ? "",
      postInstall ? "",
      meta ? { },
      ...
    }@args:
    mkLibrary {
      inherit
        pname
        version
        src
        nativeBuildInputs
        buildInputs
        postInstall
        meta
        ;

      configurePhase = ''
        runHook preConfigure

        # Copy source with write permissions
        cp -r ${src}/* .
        chmod -R u+w .

        ${crossEnvSetup}
        ${mkDepFlags buildInputs}
        ${preConfigure}

        # Run configure with cross-compilation settings
        ./configure \
          --host=${redoxTarget} \
          --build=${pkgs.stdenv.buildPlatform.config} \
          --prefix=$out \
          ${lib.concatStringsSep " \\\n          " configureFlags}

        runHook postConfigure
      '';

      buildPhase = ''
        runHook preBuild
        ${preBuild}
        make -j $NIX_BUILD_CORES
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        make install
        runHook postInstall
      '';
    };

  # Build a C library using cmake
  mkCmake =
    {
      pname,
      version ? "unstable",
      src,
      nativeBuildInputs ? [ ],
      buildInputs ? [ ],
      cmakeFlags ? [ ],
      preConfigure ? "",
      postInstall ? "",
      meta ? { },
      ...
    }:
    mkLibrary {
      inherit
        pname
        version
        src
        postInstall
        meta
        ;

      nativeBuildInputs = nativeBuildInputs ++ [ pkgs.cmake ];

      configurePhase = ''
        runHook preConfigure

        # Copy source with write permissions
        cp -r ${src}/* .
        chmod -R u+w .

        ${crossEnvSetup}
        ${mkDepFlags buildInputs}
        ${preConfigure}

        mkdir -p build && cd build

        cmake .. \
          -DCMAKE_INSTALL_PREFIX=$out \
          -DCMAKE_SYSTEM_NAME=Redox \
          -DCMAKE_SYSTEM_PROCESSOR=${targetArch} \
          -DCMAKE_C_COMPILER=${cc} \
          -DCMAKE_CXX_COMPILER=${cxx} \
          -DCMAKE_AR=${ar} \
          -DCMAKE_RANLIB=${ranlib} \
          -DCMAKE_FIND_ROOT_PATH="${sysroot}" \
          -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
          -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
          -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
          -DCMAKE_C_FLAGS="${baseCFlags}" \
          -DCMAKE_EXE_LINKER_FLAGS="${baseLdFlags}" \
          ${lib.concatStringsSep " \\\n          " cmakeFlags}

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
        runHook postInstall
      '';
    };
}
