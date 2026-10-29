# redox-kprofiling - kernel profiling data converter
#
# Converts Redox kernel profiling data into perf script format.
# Runs on the host (Linux), not on Redox.
# Builds the upstream profiling and binary size analysis tools.
#
# Source: gitlab.redox-os.org/redox-os/kprofiling

{ pkgs, lib, kprofiling-src, ... }:

pkgs.rustPlatform.buildRustPackage {
  pname = "redox-kprofiling";
  version = "0.2.2";
  src = kprofiling-src;

  cargoHash = "sha256-wc5TDc1b7/+ctcDg6P0yuOlSgK5ukIjuer4mSGEayRc=";

  meta = with lib; {
    description = "Redox kernel profiling data to perf script converter";
    homepage = "https://gitlab.redox-os.org/redox-os/kprofiling";
    license = licenses.mit;
  };
}
