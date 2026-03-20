# snix-upstream-source — Extract upstream snix crates and apply Redox patches
#
# Fetches the snix monorepo at a pinned commit, extracts the crate
# subdirectories we need, and applies the Redox systems patch to
# snix-eval. The output is a directory tree that snix-redox references
# as workspace members (under `upstream/`).
#
# Extracted crates:
#   nix-compat, nix-compat-derive, eval, eval/builtin-macros,
#   glue, store, castore, build, serde, tracing, cli/base
#
# Patches applied:
#   eval/src/systems.rs — add "redox" to is_second_coordinate()

{ pkgs }:

let
  snixSrc = pkgs.fetchgit {
    url = "https://git.snix.dev/snix/snix.git";
    rev = "eee477929d6b500936556e2f8a4e187d37525365";
    hash = "sha256-S252v2faotFqhRPoRl+2SBLdFOxjzKlWTRncQPcOtts=";
  };

  crates = [
    "nix-compat"
    "nix-compat-derive"
    "eval"
    "glue"
    "store"
    "castore"
    "build"
    "serde"
    "tracing"
    "cli/base"
  ];

in
pkgs.runCommand "snix-upstream-source" { } ''
  mkdir -p $out/cli

  ${builtins.concatStringsSep "\n" (map (crate: ''
    cp -r ${snixSrc}/snix/${crate} $out/${crate}
  '') crates)}

  # Make eval writable for patching
  chmod -R u+w $out/eval

  # Apply Redox systems patch: add "redox" to is_second_coordinate()
  patch -d $out/eval -p1 <<'PATCH'
--- a/src/systems.rs
+++ b/src/systems.rs
@@ -1,7 +1,7 @@
 /// true iff the argument is recognized by cppnix as the second
 /// coordinate of a "nix double"
 fn is_second_coordinate(x: &str) -> bool {
-    matches!(x, "linux" | "darwin" | "netbsd" | "openbsd" | "freebsd")
+    matches!(x, "linux" | "darwin" | "netbsd" | "openbsd" | "freebsd" | "redox")
 }

 /// This function takes an llvm triple (which may have three or four
PATCH

  # Create proto path resolution structure.
  # The build.rs files reference protos as "snix/{crate}/protos/..." and
  # look for PROTO_ROOT env var (or default to "../..").
  # Create a snix/ directory with symlinks so the proto paths resolve
  # when PROTO_ROOT points here.
  mkdir -p $out/snix
  for crate in castore store build; do
    ln -s ../$crate $out/snix/$crate
  done

  # Strip write bits to match Nix store conventions
  chmod -R a-w $out
''
