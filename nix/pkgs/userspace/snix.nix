# snix — Nix evaluator and binary cache client for Redox OS
#
# Built on snix-eval (bytecode VM) and nix-compat (sync NAR/store path handling).
# Cross-compiles to x86_64-unknown-redox with zero platform-specific code.
#
# Binary: snix
# Commands: eval, show-derivation, fetch, path-info, store-verify, repl
#
# Source: in-tree (snix-redox/)

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  snix-redox-src,
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
      ;
  };

in
mkUserspace.mkBinary {
  pname = "snix-redox";
  version = "0.3.0";
  src = snix-redox-src;
  binaryName = "snix";

  # Vendor hash — includes git dependency on snix-eval from git.snix.dev
  vendorHash = "sha256-I3FkNitdYBQnw5TPZeI4Ej1FTJQnMDGLtle3Ya8DwSI=";

  # snix-eval is fetched from git (along with snix-eval-builtin-macros)
  gitSources = [
    {
      url = "git+https://git.snix.dev/snix/snix.git";
      git = "https://git.snix.dev/snix/snix.git";
    }
  ];

  # Patch snix-eval's systems.rs to recognize "redox" as a valid OS.
  # Without this, pure_builtins() panics on llvm_triple_to_nix_double("x86_64-unknown-redox")
  # because is_second_coordinate() only knows linux/darwin/netbsd/openbsd/freebsd.
  # The panic (with panic=abort) emits ud2, causing "Invalid opcode fault" on every eval call.
  postConfigure = ''
        if [ -d vendor-combined/snix-eval-0.1.0 ]; then
          echo "Patching snix-eval systems.rs for Redox OS support..."
          substituteInPlace vendor-combined/snix-eval-0.1.0/src/systems.rs \
            --replace-fail \
              'matches!(x, "linux" | "darwin" | "netbsd" | "openbsd" | "freebsd")' \
              'matches!(x, "linux" | "darwin" | "netbsd" | "openbsd" | "freebsd" | "redox")'

          # Regenerate checksum for the patched crate
          ${pkgs.python3}/bin/python3 -c "
    import hashlib, json, os, pathlib

    crate_dir = pathlib.Path('vendor-combined/snix-eval-0.1.0')
    checksum_file = crate_dir / '.cargo-checksum.json'
    data = json.loads(checksum_file.read_text())
    files = {}
    for path in sorted(crate_dir.rglob('*')):
        if path.is_file() and path.name != '.cargo-checksum.json':
            rel = str(path.relative_to(crate_dir))
            h = hashlib.sha256(path.read_bytes()).hexdigest()
            files[rel] = h
    data['files'] = files
    checksum_file.write_text(json.dumps(data, sort_keys=True))
    "
        fi
  '';

  meta = with lib; {
    description = "Nix evaluator and binary cache client for Redox OS";
    mainProgram = "snix";
  };
}
