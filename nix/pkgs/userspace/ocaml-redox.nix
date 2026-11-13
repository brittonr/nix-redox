# Linux-executed OCaml compiler for x86_64 Redox, using upstream crossopt.
#
# Interface:
#   out/bin/{ocamlc,ocamlopt}: host-native compilers producing Redox code
#   out/bin/ocamlrun: matching HOST interpreter for compiler build tools
#   out/lib/ocaml: TARGET stdlib, Unix/systhreads stubs, archives and caml headers
#   passthru.runtime/bin/ocamlrun: statically linked REDOX bytecode interpreter
# Only runtime (not out/bin) belongs in a guest image. Bytecode executables use
# /bin/ocamlrun in the guest; native executables use relibc and its real pthreads.
# Shared/native dynlink is unavailable on this static target; Unix, domains,
# systhreads, signals and effect handlers are not replaced or disabled.
{
  pkgs,
  lib,
  redoxTarget,
  relibc,
  hostOcaml ? pkgs.ocamlPackages.ocaml,
  ...
}:

let
  version = "5.4.1";
  mkCLibrary = import ./mk-c-library.nix {
    inherit
      pkgs
      lib
      redoxTarget
      relibc
      ;
  };
  sysroot = "${relibc}/${redoxTarget}";

  # relibc currently installs GCC's stdatomic.h, which is incompatible with
  # Clang's _Atomic types. Use Clang's actual C11 intrinsic implementation,
  # without its usual include_next delegation back to that GCC-only header.
  atomicHeaders = pkgs.runCommand "ocaml-redox-clang-atomic-headers" { } ''
    mkdir -p "$out"
    resourceDir="$(${pkgs.llvmPackages.clang-unwrapped}/bin/clang -print-resource-dir)"
    cp "$resourceDir/include/stdatomic.h" "$out/stdatomic.h"
    substituteInPlace "$out/stdatomic.h" \
      --replace-fail '__has_include_next(<stdatomic.h>)' '0 /* relibc header is GCC-only */'
  '';

  # mk-c-library supplies the relibc CRT/link interface. Embed the target flags
  # in CC itself: configure's CFLAGS are not retained in Config.c_compiler, and
  # later ocamlc/ocamlopt C-stub compilations must never fall back to host libc.
  # Clang's Redox driver does not imply _REENTRANT for -pthread; the CRT
  # wrapper already links real libpthread, so request its threaded headers.
  targetCC = pkgs.writeShellScript "ocaml-redox-cc" ''
    for arg in "$@"; do
      case "$arg" in
        -c|-S|-E|-M|-MM)
          exec ${mkCLibrary.ccWrapper} \
            --target=${redoxTarget} --sysroot=${sysroot} \
            -D__redox__ -D_REENTRANT -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 \
            -I${atomicHeaders} -I${sysroot}/include -fPIC "$@"
          ;;
      esac
    done
    # Clang's Redox linker driver invokes gcc. Pin the unwrapped driver so
    # no-CC derivations can link, without a Nix GCC wrapper adding host libc.
    export PATH="${pkgs.stdenv.cc.cc}/bin:${pkgs.llvmPackages.lld}/bin:$PATH"
    exec ${mkCLibrary.ccWrapper} \
      --target=${redoxTarget} --sysroot=${sysroot} \
      -D__redox__ -D_REENTRANT -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 \
      -I${atomicHeaders} -I${sysroot}/include -L${sysroot}/lib -fPIC -fuse-ld=lld "$@"
  '';

  toolchain = pkgs.stdenv.mkDerivation {
    pname = "ocaml-redox-cross";
    inherit version;
    src = hostOcaml.src;
    outputs = [
      "out"
      "targetRuntime"
    ];

    patches = [
      ./patches/ocaml-redox-amd64.patch
      ./patches/ocaml-auxv-security.patch
    ];

    nativeBuildInputs = [
      hostOcaml
      pkgs.autoconf
      pkgs.gnumake
      pkgs.pkg-config
      pkgs.llvmPackages.clang
      pkgs.llvmPackages.bintools
      pkgs.llvmPackages.lld
      # Makefile.cross links host libcomprmarsh using the host compiler's
      # compression_c_libraries, independent of --without-zstd on the target.
      pkgs.zstd
    ];

    # Mixed host executables and target objects: neither patchelf nor the
    # stdenv host strip pass may rewrite the target runtime/static archives.
    dontFixup = true;
    dontStrip = true;
    strictDeps = true;

    configurePhase = ''
      runHook preConfigure

      # Upstream explicitly requires the exact same bootstrap version. Check
      # both programs, since an accidental PATH mix is otherwise very subtle.
      test "$(${hostOcaml}/bin/ocamlc -vnum)" = ${version}
      test "$(${hostOcaml}/bin/ocamlopt -vnum)" = ${version}
      export PATH="${hostOcaml}/bin:$PATH"

      # Regenerate configure after adding the genuine Redox backend identity.
      autoconf
      ${mkCLibrary.crossEnvSetupWithWrapper}
      export CC=${targetCC}
      export AS="$CC -c"
      export ASPP="$CC -c"
      export DIRECT_LD=${pkgs.llvmPackages.lld}/bin/ld.lld
      export CC_FOR_BUILD=${pkgs.stdenv.cc}/bin/cc
      export CFLAGS_FOR_BUILD=""
      export CPPFLAGS_FOR_BUILD=""
      export LDFLAGS_FOR_BUILD=""

      ./configure \
        --prefix="$out" \
        --libdir="$out/lib/ocaml" \
        --build=${pkgs.stdenv.buildPlatform.config} \
        --host=${pkgs.stdenv.hostPlatform.config} \
        --target=${redoxTarget} \
        --enable-native-compiler \
        --disable-shared \
        --disable-ocamldoc \
        --disable-ocamldebug \
        --disable-ocamltest \
        --disable-installing-bytecode-programs \
        --without-zstd \
        --with-target-sh=/bin/sh \
        TARGET_BINDIR=/bin TARGET_LIBDIR=/lib/ocaml

      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild
      # These are the official host-compiler overrides, not a target world.opt
      # build. In particular the build must never execute runtime/ocamlrun.
      make -j"$NIX_BUILD_CORES" crossopt OCAMLRUN=ocamlrun NEW_OCAMLRUN=ocamlrun
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      make installcross

      mkdir -p "$targetRuntime/bin"
      # installcross intentionally installs target runtimes next to host
      # compilers. Split them before exposing bin on a Linux build PATH.
      for program in "$out"/bin/ocamlrun*; do
        mv "$program" "$targetRuntime/bin/"
      done
      ln -s ${hostOcaml}/bin/ocamlrun "$out/bin/ocamlrun"

      # ocamlyacc is a C program built for target by crossopt. Build tools need
      # the version-matched host executable, not this target ELF. ocamllex.opt
      # is already the host tool selected by upstream installcross.
      rm "$out/bin/ocamlyacc"
      ln -s ${hostOcaml}/bin/ocamlyacc "$out/bin/ocamlyacc"

      runHook postInstall
    '';

    passthru = {
      inherit hostOcaml targetCC redoxTarget;
      runtime = toolchain.targetRuntime;
      targetOcamlLib = "${toolchain}/lib/ocaml";
      targetSysroot = sysroot;
      targetRuntimePath = "/bin/ocamlrun";
      # Consumers must use the host compiler to execute PPX/build generators,
      # and this derivation to compile target libraries and final programs.
      isCross = true;
      nativeCompilers = true;
      ocamlVersion = version;
    };

    meta = {
      description = "OCaml 5.4.1 host-native cross compiler and runtime for Redox";
      homepage = "https://ocaml.org/";
      license = lib.licenses.lgpl21Only;
      platforms = [ "x86_64-linux" ];
    };
  };

in
assert lib.asserts.assertMsg (
  hostOcaml.version == version
) "ocaml-redox requires a matching OCaml ${version} host compiler and source";
assert lib.asserts.assertMsg (
  redoxTarget == "x86_64-unknown-redox"
) "ocaml-redox currently implements only the x86_64 Redox ABI";
toolchain
