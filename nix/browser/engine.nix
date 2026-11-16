# The import contains only the upstream engine, never its Linux vm.state.
# Source rebuilding uses Docker/Emscripten, not a Nix-native WASM toolchain.
{ pkgs }:
let
  inherit (pkgs) lib;
  pins = builtins.fromJSON (builtins.readFile ./engine-pins.json);
  trynixSource = pkgs.fetchFromGitHub {
    owner = "fzakaria";
    repo = "trynix";
    rev = pins.trynixRevision;
    hash = pins.trynixNarHash;
  };
  qemuSource = pkgs.fetchFromGitHub {
    owner = "ktock";
    repo = "qemu-wasm";
    rev = pins.qemuRevision;
    hash = pins.qemuNarHash;
  };
  dependencies = import ./dependencies.nix { inherit pkgs; };
  sourceBundle =
    pkgs.runCommand "redox-browser-engine-source-notices"
      {
        nativeBuildInputs = [
          pkgs.gnutar
          pkgs.gzip
          pkgs.xz
        ];
      }
      ''
        mkdir -p $out/licenses $out/source
        cp ${qemuSource}/COPYING $out/licenses/QEMU-COPYING
        cp ${qemuSource}/COPYING.LIB $out/licenses/QEMU-COPYING.LIB
        cp ${qemuSource}/LICENSE $out/licenses/QEMU-LICENSE
        cp ${trynixSource}/LICENSE $out/licenses/TryNix-MIT.txt
        cp ${../../LICENSE} $out/licenses/nix-redox-MIT.txt
        cp ${dependencies.libffi}/LICENSE $out/licenses/libffi-LICENSE
        cp ${dependencies.emscripten}/LICENSE $out/licenses/Emscripten-LICENSE
        cp ${dependencies.emscripten}/AUTHORS $out/licenses/Emscripten-AUTHORS
        cp ${dependencies.emscripten}/system/lib/libc/musl/COPYRIGHT $out/licenses/musl-COPYRIGHT
        tar -xOf ${dependencies.glib} glib-2.75.0/LICENSES/LGPL-2.1-or-later.txt > $out/licenses/GLib-COPYING
        tar -xOf ${dependencies.pixman} pixman-0.42.2/COPYING > $out/licenses/pixman-COPYING
        tar -xOf ${dependencies.zlib} zlib-1.3.1/LICENSE > $out/licenses/zlib-LICENSE
        cp -r ${vendor}/licenses/. $out/licenses/
        cp -r ${vendor}/source/. $out/source/
        cp ${./engine-pins.json} $out/source/engine-pins.json
        cp ${./dependencies.nix} $out/source/dependencies.nix
        cp ${./engine.nix} $out/source/engine.nix
        cp ${./vendor.nix} $out/source/vendor.nix
        cp ${./machine.json} $out/source/machine.json
        cp -r ${./patches} $out/source/patches
        cp ${./build-engine.sh} $out/source/build-engine.sh
        cp ${./finalize-engine.py} $out/source/finalize-engine.py
        cp ${./native-qemu.nix} $out/source/native-qemu.nix
        cp ${dependencies.glib} $out/source/glib-2.75.0.tar.xz
        cp ${dependencies.pixman} $out/source/pixman-0.42.2.tar.gz
        cp ${dependencies.zlib} $out/source/zlib-1.3.1.tar.xz
        tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner -C ${qemuSource} -czf $out/source/qemu-wasm.tar.gz .
        tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner -C ${trynixSource} -czf $out/source/trynix.tar.gz .
        tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner -C ${dependencies.libffi} -czf $out/source/libffi.tar.gz .
        tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner -C ${dependencies.emscripten} -czf $out/source/emscripten.tar.gz .
      '';
  nativeQemu = import ./native-qemu.nix { inherit pkgs trynixSource; };
  nativeProvenance =
    pkgs.runCommand "redox-browser-native-identity.json"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        python3 - <<'PY' > $out
        import hashlib, json, pathlib
        p = pathlib.Path("${nativeQemu}/bin/qemu-system-x86_64")
        print(json.dumps({"qemuRevision": "${pins.qemuRevision}", "trynixRevision": "${pins.trynixRevision}", "derivation": "${nativeQemu}", "genericHostTicks": True, "executable": {"sha256": hashlib.sha256(p.read_bytes()).hexdigest(), "size": p.stat().st_size}}, indent=2))
        PY
      '';
  engineFiles = lib.mapAttrs (
    name: hash:
    pkgs.fetchurl {
      url = "${pins.baseUrl}/${pins.tag}/${name}";
      inherit hash;
    }
  ) pins.files;
  engine =
    pkgs.runCommand "redox-browser-engine-${pins.tag}"
      {
        nativeBuildInputs = [
          pkgs.gnutar
          pkgs.gzip
          pkgs.python3
        ];
      }
      ''
        mkdir -p $out/licenses $out/source
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: source: "cp ${source} $out/${name}") engineFiles
        )}
        cp ${./engine-pins.json} $out/engine-pins.json
        cp -r ${sourceBundle}/. $out/
        chmod -R u+w $out
        python3 ${./finalize-engine.py} $out --pins ${./engine-pins.json}
      '';
  firmware = pkgs.runCommand "redox-browser-firmware" { } ''
    mkdir -p $out/licenses
    cp -r ${qemuSource}/pc-bios/. $out/
    chmod -R u+w $out
    cp ${pkgs.OVMF.fd}/FV/OVMF.fd $out/OVMF.fd
    cp ${qemuSource}/pc-bios/README $out/licenses/QEMU-PC-BIOS-README
    cp ${pkgs.OVMF.src}/License.txt $out/licenses/OVMF-License.txt
    cp ${qemuSource}/COPYING $out/licenses/QEMU-COPYING
    cp ${qemuSource}/LICENSE $out/licenses/QEMU-LICENSE
  '';
  vendor = import ./vendor.nix { inherit pkgs; };
  buildEngine = pkgs.writeShellApplication {
    name = "build-browser-engine";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      docker
      rsync
      patch
      gnused
      findutils
      python3
      gnutar
      gzip
    ];
    text = ''
      export REDOX_ENGINE_SOURCE=${qemuSource}
      export TRYNIX_SOURCE=${trynixSource}
      export REDOX_EMSDK_IMAGE=${pins.toolchain.emsdkImage}
      export REDOX_ENGINE_PATCHES=${./patches}
      export REDOX_SOURCE_BUNDLE=${sourceBundle}
      exec bash ${./build-engine.sh} "$@"
    '';
  };
in
{
  inherit
    engine
    nativeQemu
    nativeProvenance
    firmware
    vendor
    buildEngine
    qemuSource
    trynixSource
    sourceBundle
    ;
  machine = ./machine.json;
  pins = ./engine-pins.json;
  toolDirectory = ./.;
}
