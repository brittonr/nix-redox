# Target foreign bindings for Nixtamal's OCaml 5.4 library closure. The host
# packages supply SOURCES only: no Linux object, generated ABI constant, or
# compiled OCaml package is an input to this derivation.
{
  pkgs,
  lib,
  redoxTarget,
  relibc,
  ocamlCross,
  hostPackages,
  ...
}:
let
  sources = {
    inherit (hostPackages)
      eio
      eio_posix
      iomux
      mtime
      stdint
      bigstringaf
      cstruct
      xdg
      ;
  };
  archiveNames = [
    "libeio_posix_stubs.a"
    "libeio_unix_stubs.a"
    "libiomux_stubs.a"
    "libmtime_clock_stubs.a"
    "libstdint_stubs.a"
    "libbigstringaf_stubs.a"
    "libcstruct_stubs.a"
    "libxdg_stubs.a"
  ];
  ar = "${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-ar";
  # Preserve Dune's dependency tracking while replacing host-header discovery.
  # These units are for target bytecode; their target constants cannot be
  # exercised against the Linux C archives built by the host Dune derivations.
  configureBytecodePackages =
    scope:
    scope.overrideScope (
      _self: prev: {
        eio = prev.eio.overrideAttrs (old: {
          doCheck = false;
          postPatch = (old.postPatch or "") + ''
            cp ${targetStubs}/share/ocaml-stubs-redox/eio_unix/config.ml lib_eio/unix/redox-config.inc
            substituteInPlace lib_eio/unix/dune --replace-fail \
              '(action (run ./include/discover.exe))' \
              '(action (copy redox-config.inc config.ml))'
          '';
        });
        eio_posix = prev.eio_posix.overrideAttrs (old: {
          doCheck = false;
          postPatch = (old.postPatch or "") + ''
            cp ${targetStubs}/share/ocaml-stubs-redox/eio_posix/config.ml lib_eio_posix/redox-config.inc
            substituteInPlace lib_eio_posix/dune --replace-fail \
              '(action (run ./include/discover.exe))' \
              '(action (copy redox-config.inc config.ml))'
          '';
        });
        iomux = prev.iomux.overrideAttrs (old: {
          doCheck = false;
          postPatch = (old.postPatch or "") + ''
            cp ${targetStubs}/share/ocaml-stubs-redox/iomux/config.ml lib/redox-config.inc
            cp ${targetStubs}/share/ocaml-stubs-redox/iomux/config.h lib/redox-config.h.in
            substituteInPlace lib/dune --replace-fail \
              '(run ./include/discover.exe)' \
              '(progn (copy redox-config.inc config.ml) (copy redox-config.h.in config.h))'
          '';
        });
      }
    );
  targetStubs =
    assert lib.asserts.assertMsg (
      redoxTarget == "x86_64-unknown-redox"
    ) "OCaml foreign bindings currently target the x86_64 Redox ABI";
    assert lib.asserts.assertMsg (
      ocamlCross.version == hostPackages.ocaml.version
    ) "OCaml foreign bindings require matching host and target Caml headers";
    pkgs.runCommand "ocaml-stubs-redox-${ocamlCross.version}"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.gnutar
          pkgs.bzip2
          pkgs.gzip
          pkgs.xz
          pkgs.patch
        ];
        passthru = {
          inherit archiveNames configureBytecodePackages;
          # Link the foreign archives and target OCaml archives in one --start-group /
          # --end-group, through ocamlCross.targetCC (which supplies relibc and CRT).
          linkFlags = [ "-pthread" ];
          targetConfigDirectory = "share/ocaml-stubs-redox";
        };
        meta = {
          description = "Real Redox static C bindings for the Nixtamal OCaml library graph";
          platforms = [ "x86_64-linux" ];
        };
      }
      ''
        export CC=${ocamlCross.targetCC}
        mkdir -p "$out/lib" "$out/share/ocaml-stubs-redox" \
          "$out/share/licenses/ocaml-bindings" sources objects

        unpack_source() {
          name="$1"
          src="$2"
          mkdir -p "sources/$name"
          if [ -d "$src" ]; then
            cp -R "$src"/. "sources/$name/"
          else
            tar -xf "$src" --strip-components=1 -C "sources/$name"
          fi
          chmod -R u+w "sources/$name"
        }
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: package: ''
            unpack_source ${lib.escapeShellArg name} ${lib.escapeShellArg (toString package.src)}
          '') sources
        )}

        patch -d sources/eio_posix -p1 < ${./patches/eio-redox-getrandom.patch}
        patch -d sources/iomux -p1 < ${./patches/iomux-redox-unistd.patch}
        patch -d sources/mtime -p1 < ${./patches/ocaml-stubs-mtime-redox.patch}

        # Eio's open/at flags and iomux's poll bits/struct size belong to relibc.
        # Clang emits constant initializers to target LLVM IR; nothing is executed.
        python3 ${./patches/ocaml-stubs-target-config.py} "$out/share/ocaml-stubs-redox"
        cp "$out/share/ocaml-stubs-redox/iomux/config.h" sources/iomux/lib/config.h

        cflags=(
          -O2 -std=gnu11 -fno-strict-aliasing -fwrapv -pthread
          -D_FILE_OFFSET_BITS=64 -D_LARGEFILE64_SOURCE
          -Werror=implicit-function-declaration
          -I${ocamlCross}/lib/ocaml
        )

        compile_archive() {
          archive="$1"
          directory="$2"
          shift 2
          mkdir -p "objects/$archive"
          objects=()
          for source in "$@"; do
            object="objects/$archive/$(basename "$source" .c).o"
            "$CC" "''${cflags[@]}" -I"$directory" \
              -Isources/eio/lib_eio/unix/include \
              -c "$directory/$source" -o "$object"
            objects+=("$object")
          done
          ${ar} rcsD "$out/lib/$archive" "''${objects[@]}"
        }

        compile_archive libeio_unix_stubs.a sources/eio/lib_eio/unix \
          fork_action.c eio_unix_stubs.c cap.c pty.c
        compile_archive libeio_posix_stubs.a sources/eio_posix/lib_eio_posix eio_posix_stubs.c
        compile_archive libiomux_stubs.a sources/iomux/lib iomux_stubs.c
        compile_archive libmtime_clock_stubs.a sources/mtime/src/clock mtime_clock_stubs.c
        compile_archive libbigstringaf_stubs.a sources/bigstringaf/lib bigstringaf_stubs.c
        compile_archive libcstruct_stubs.a sources/cstruct/lib cstruct_stubs.c
        compile_archive libxdg_stubs.a sources/xdg/otherlibs/xdg xdg_stubs.c
        compile_archive libstdint_stubs.a sources/stdint/lib \
          float_conv.c int128_conv.c int128_stubs.c int16_conv.c int24_conv.c \
          int32_conv.c int40_conv.c int40_stubs.c int48_conv.c int48_stubs.c \
          int56_conv.c int56_stubs.c int64_conv.c int8_conv.c int_conv.c \
          nativeint_conv.c uint128_conv.c uint128_stubs.c uint16_conv.c uint24_conv.c \
          uint32_conv.c uint32_stubs.c uint40_conv.c uint40_stubs.c uint48_conv.c \
          uint48_stubs.c uint56_conv.c uint56_stubs.c uint64_conv.c uint64_stubs.c uint8_conv.c

        # Keep upstream notices with the statically linked providers, including
        # notices nested below the root. Pure OCaml dependencies are parent-owned.
        python3 - "$out/share/licenses/ocaml-bindings" <<'PY'
        from pathlib import Path
        import shutil
        import sys
        destination = Path(sys.argv[1])
        for provider in Path("sources").iterdir():
            for source in provider.rglob("*"):
                if source.is_file() and source.name.lower().startswith(("license", "licence", "copying", "copyright", "notice")):
                    target = destination / provider.name / source.relative_to(provider)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source, target)
        PY
      '';
in
targetStubs
