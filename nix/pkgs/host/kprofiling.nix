# redox-kprofiling - kernel profiling data converter
#
# Converts Redox kernel profiling data into perf script format.
# Runs on the host (Linux), not on Redox.
# Only dependency is anyhow. Requires nightly (#![feature(iter_next_chunk)]).
#
# Source: gitlab.redox-os.org/redox-os/kprofiling

{ pkgs, lib, kprofiling-src, rustToolchain, ... }:

let
  rustPlatform = pkgs.makeRustPlatform {
    rustc = rustToolchain;
    cargo = rustToolchain;
  };
in
rustPlatform.buildRustPackage {
  pname = "redox-kprofiling";
  version = "0.1.0";
  src = kprofiling-src;

  cargoHash = "sha256-wc5TDc1b7/+ctcDg6P0yuOlSgK5ukIjuer4mSGEayRc=";

  meta = with lib; {
    description = "Redox kernel profiling data to perf script converter";
    homepage = "https://gitlab.redox-os.org/redox-os/kprofiling";
    license = licenses.mit;
  };
}
