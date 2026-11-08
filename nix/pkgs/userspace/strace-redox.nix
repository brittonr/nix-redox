# strace-redox - System call tracer for Redox OS
#
# A Rust implementation of strace for Redox OS. Traces system calls
# and signals for debugging.
#
# Source: gitlab.redox-os.org/redox-os/strace-redox (Redox-native)
# Binary: strace

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  unit2nixVendor,
  strace-redox-src,
  ...
}:

let
  mkUserspace = import ./mk-userspace.nix {
    inherit
      pkgs
      lib
      rustToolchain
      sysrootVendor
      redoxTarget
      relibc
      stubLibs
      vendor
      unit2nixVendor
      ;
  };

in
mkUserspace.mkBinary {
  pname = "strace-redox";
  src = strace-redox-src;
  binaryName = "strace";

  vendorHash = "sha256-mz5MtGbCxzaQ2pmP5oswxJcUi7l8agSkD/wikkl3g/M=";

  # redox_syscall 0.3.4 getpid/kill/waitpid are legacy syscalls that the
  # refreshed kernel rejects with ENOSYS; use libc's proc-scheme paths.
  nativeBuildInputs = [ pkgs.python3 ];
  preConfigure = ''
    python3 ${./patches/patch-strace-libc-process.py} .
  '';
  # The advanced mode still uses the legacy event: API; the simple blocking
  # tracer is what the proc: trace handle implements.
  cargoBuildFlags = "--no-default-features --bin strace";

  gitSources = [
    {
      url = "git+https://gitlab.redox-os.org/redox-os/liblibc.git?branch=rust-2022-03-18";
      git = "https://gitlab.redox-os.org/redox-os/liblibc.git";
      branch = "rust-2022-03-18";
    }
  ];

  meta = with lib; {
    description = "System call tracer for Redox OS";
    homepage = "https://gitlab.redox-os.org/redox-os/strace-redox";
    license = licenses.mit;
    mainProgram = "strace";
  };
}
