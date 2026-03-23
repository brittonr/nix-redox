# Precompile WASM modules to Pulley bytecode (.cwasm) for Redox
#
# Uses the host wasmtime to compile .wat/.wasm files to .cwasm
# targeting the Pulley interpreter. The output .cwasm files are
# included in Redox disk images for execution.
#
# NOTE: The host wasmtime version must match the cross-compiled
# Redox wasmtime version for .cwasm compatibility. If nixpkgs
# wasmtime version diverges, this derivation needs updating.

{ pkgs, ... }:

let
  wasmtime = pkgs.wasmtime;
  helloWat = ../../../examples/wasm/hello.wat;
in
pkgs.stdenv.mkDerivation {
  pname = "wasmtime-precompiled-modules";
  version = "0.1.0";

  dontUnpack = true;

  nativeBuildInputs = [ wasmtime ];

  buildPhase = ''
    export HOME=$(mktemp -d)
    echo "Precompiling WASM modules with wasmtime $(wasmtime --version)"
    echo "Target: pulley64"

    mkdir -p modules

    # Compile hello.wat to Pulley bytecode
    wasmtime compile --target pulley64 ${helloWat} -o modules/hello.cwasm
    echo "hello.cwasm: $(ls -la modules/hello.cwasm | awk '{print $5}') bytes"
  '';

  installPhase = ''
    mkdir -p $out/share/wasm
    cp modules/*.cwasm $out/share/wasm/

    # Also include the source .wat for on-device compilation testing
    cp ${helloWat} $out/share/wasm/hello.wat
  '';

  meta = {
    description = "Precompiled WASM modules (Pulley bytecode) for Redox";
  };
}
