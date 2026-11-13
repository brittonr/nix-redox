# Upstream Nixtamal, embedded as portable OCaml bytecode and linked for Redox.
# Only the generated C, target OCaml runtime and target C bindings enter the
# guest executable. PPX generators and the matching compiler run on the host.
{
  pkgs,
  lib,
  redoxTarget,
  relibc,
  ...
}:
let
  version = "3.1.0";

  # Nixtamal's own release pins this package set. The repository's older
  # package set has Eio 1.3, while Nixtamal 3 requires Eio >= 1.6.
  dependencyPkgs = import (builtins.fetchTarball {
    url = "https://releases.nixos.org/nixpkgs/nixpkgs-26.11pre1115905.9ac0edc06bfb/nixexprs.tar.zst";
    sha256 = "sha256-BszPqU/Au5mm0nQIDUMnsksh6hgIp7iyaX/UBcuRa0c=";
  }) { system = pkgs.stdenv.buildPlatform.system; };

  hostPackages = dependencyPkgs.ocamlPackages.overrideScope (
    self: prev: {
      # Bytecode and the embedded target runtime must agree on the OCaml ABI.
      ocaml = pkgs.ocamlPackages.ocaml;
      # Keep host tools working while the guest selects its bundled Unicode data.
      camomile = prev.camomile.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./patches/camomile-runtime-data.patch ];
      });
      eio_main = prev.eio_main.overrideAttrs (_: {
        # Use upstream's POSIX selection; Linux io_uring is not a Redox backend.
        propagatedBuildInputs = [ self.eio_posix ];
      });
      jsont = prev.jsont.override {
        withBrr = false;
        withBytesrw = true;
        withTypegist = false;
      };
    }
  );

  src = pkgs.fetchdarcs {
    url = "https://smeder.ee/~toastal/nixtamal.darcs/";
    rev = "3.1.0";
    hash = "sha256-AW9jcfnGM1Wi3bPKBfP8rZXjRAbwn8FIlue3SxgWGIA=";
  };

  ocamlCross = import ./ocaml-redox.nix {
    inherit
      pkgs
      lib
      redoxTarget
      relibc
      ;
    hostOcaml = hostPackages.ocaml;
  };

  targetStubs = import ./ocaml-stubs-redox.nix {
    inherit
      pkgs
      lib
      redoxTarget
      relibc
      ocamlCross
      hostPackages
      ;
  };

  # Eio's generated ML constants must describe relibc even though the compiler
  # and PPX tools execute on Linux. C and ML configuration share one provider.
  bytecodePackages = targetStubs.configureBytecodePackages hostPackages;

  bytecode = bytecodePackages.buildDunePackage {
    pname = "nixtamal-redox-bytecode";
    inherit version src;
    outputs = [ "out" ];
    doCheck = false;

    buildInputs = with bytecodePackages; [
      camomile
      cmdliner
      eio
      eio_main
      eio_posix
      fmt
      jingoo
      jsont
      kdl
      logs
      mtime
      ppx_blob
      ppx_deriving
      ppx_deriving_qcheck
      qcheck-core
      saturn
      stdint
      xdg
    ];

    postPatch = ''
      substituteInPlace bin/main.ml --replace-fail '@version@' '${version}'
      substituteInPlace lib/lock_loader.ml --replace-fail '@release_year@' '2026'
      substituteInPlace bin/dune \
        --replace-fail '(public_name nixtamal)' '(public_name nixtamal) (modes (byte c) exe)'
    '';

    buildPhase = ''
      runHook preBuild
      dune build --profile release -p nixtamal -j "$NIX_BUILD_CORES" bin/main.bc.c
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/share/nixtamal"
      cp _build/default/bin/main.bc.c "$out/share/nixtamal/main.bc.c"
      runHook postInstall
    '';
  };

  mkCLibrary = import ./mk-c-library.nix {
    inherit
      pkgs
      lib
      redoxTarget
      relibc
      ;
  };

  package = mkCLibrary.mkLibrary {
    pname = "nixtamal-redox";
    inherit version;
    src = bytecode;

    nativeBuildInputs = [
      pkgs.gnutar
      pkgs.xz
    ];

    configurePhase = ''
      runHook preConfigure
      export CC=${ocamlCross.targetCC}
      runHook postConfigure
    '';

    buildPhase = ''
            runHook preBuild
            cat > nixtamal-main.c <<EOF
      #include <caml/callback.h>
      #include <stdio.h>
      #include <stdlib.h>

      int main(int argc, char **argv) {
          (void)argc;
          if (setenv("NIXTAMAL_CAMOMILE_DIR", "$out/share/camomile", 0) != 0) {
              perror("nixtamal: configuring Unicode data");
              return 1;
          }
          caml_startup(argv);
          return 0;
      }
      EOF
            "$CC" -O2 -pthread -I${ocamlCross}/lib/ocaml \
              ${bytecode}/share/nixtamal/main.bc.c nixtamal-main.c \
              -Wl,--start-group \
              ${targetStubs}/lib/*.a \
              ${ocamlCross}/lib/ocaml/libunixbyt.a \
              ${ocamlCross}/lib/ocaml/libthreads.a \
              ${ocamlCross}/lib/ocaml/libcamlstrbyt.a \
              ${ocamlCross}/lib/ocaml/libcamlruntime_eventsbyt.a \
              ${ocamlCross}/lib/ocaml/libcamlrun.a \
              -Wl,--end-group -lm -ldl -o nixtamal
            runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -Dm755 nixtamal "$out/bin/nixtamal"
      mkdir -p "$out/share/licenses/nixtamal" "$TMPDIR/ocaml-license"
      cp ${src}/LICENSE.txt "$out/share/licenses/nixtamal/"
      cp -r ${src}/license "$out/share/licenses/nixtamal/upstream"
      cp -r ${targetStubs}/share/licenses/ocaml-bindings "$out/share/licenses/nixtamal/"
      cp -r ${hostPackages.camomile}/share/camomile "$out/share/camomile"
      cp ${hostPackages.camomile.src}/LICENSE.md "$out/share/licenses/nixtamal/Camomile-LICENSE.md"
      tar -xJf ${hostPackages.ocaml.src} --strip-components=1 \
        -C "$TMPDIR/ocaml-license" ocaml-${hostPackages.ocaml.version}/LICENSE
      cp "$TMPDIR/ocaml-license/LICENSE" "$out/share/licenses/nixtamal/OCaml-LICENSE"
      runHook postInstall
    '';

    meta = {
      description = "Nixtamal input pinning, running natively on Redox";
      homepage = "https://nixtamal.toast.al/";
      license = lib.licenses.gpl3Plus;
      mainProgram = "nixtamal";
    };
  };
in
package.overrideAttrs (_: {
  passthru = {
    inherit
      bytecode
      ocamlCross
      targetStubs
      src
      ;
    runtime = ocamlCross.runtime;
  };
})
