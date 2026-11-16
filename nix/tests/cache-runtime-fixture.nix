# Real Redox native executable with an observable A -> B -> C runtime closure.
# Only `package` is advertised. Neither dependency is baked into the guest store.
{
  pkgs,
  lib,
  rustToolchain,
  relibc,
  stubLibs,
  redoxTarget ? "x86_64-unknown-redox",
  namePrefix ? "cache-runtime",
}:
let
  flags = import ../lib/rust-flags.nix {
    inherit
      pkgs
      lib
      relibc
      redoxTarget
      stubLibs
      rustToolchain
      ;
  };
  c = pkgs.writeText "${namePrefix}-c" "CACHE_CLOSURE_RUNTIME_OK\n";
  b = pkgs.runCommand "${namePrefix}-b" { } ''
    mkdir -p "$out"
    ln -s ${c} "$out/message"
  '';
  package =
    pkgs.runCommand "${namePrefix}-a"
      {
        TARGET = redoxTarget;
        nativeBuildInputs = [
          rustToolchain
          pkgs.llvmPackages.clang
          pkgs.llvmPackages.lld
        ];
      }
      ''
        cat > cache-fixture.rs <<'RS'
        fn main() {
            let message = std::fs::read_to_string("${b}/message")
                .expect("runtime dependency B -> C must be installed");
            assert_eq!(message, "CACHE_CLOSURE_RUNTIME_OK\n");
            print!("{}", message);
        }
        RS
        mkdir -p "$out/bin"
        rustc --edition=2021 --target=${redoxTarget} -C opt-level=s -C debuginfo=0 \
          ${flags.userRustFlags} -L ${stubLibs}/lib \
          cache-fixture.rs -o "$out/bin/cache-closure-fixture"
      '';
  cache =
    (import ../lib/mk-binary-cache.nix {
      hostPkgs = pkgs;
      inherit lib;
    })
      {
        packages.cache-closure-fixture = package;
        target = redoxTarget;
      };
in
{
  inherit package cache;
  dependency = b;
  leaf = c;
}
