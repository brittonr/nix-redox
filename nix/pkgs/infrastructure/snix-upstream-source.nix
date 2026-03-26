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
#   glue/src/builder/mod.rs — make derivation_into_build_request public
#   glue/src/lib.rs — make fetchurl module public
#   glue/src/fetchurl.rs — make fetchurl_derivation_to_fetch and Error public
#
# Upstream pin: 34604636d7 (2026-03-26) — canon branch

{ pkgs }:

let
  snixSrc = pkgs.fetchgit {
    url = "https://git.snix.dev/snix/snix.git";
    rev = "34604636d7e3adbad6f7f909c98bb493f26855f9";
    hash = "sha256-of/rQYKmysPEqO2Snx199VcZjey+5YxJZD3QgLQanN4=";
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

  # Make crates writable for Cargo.toml patching
  chmod -R u+w $out/build $out/store $out/castore

  # Remove fuse feature requirement from snix-build → snix-castore dep.
  # Upstream snix-build unconditionally enables snix-castore/fuse, which
  # pulls in fuse-backend-rs → vm-memory (Linux-only). Since we use
  # DummyBuildService, we don't need FUSE.
  sed -i 's|snix-castore = { path = "../castore", features = \["fuse"\] }|snix-castore = { path = "../castore" }|' $out/build/Cargo.toml

  # Gate the bwrap/oci modules that use snix_castore::fs behind a
  # cargo feature so they don't compile when fs is not enabled.
  # The modules are already cfg(target_os = "linux"), but they still
  # compile on a linux host and need castore::fs.
  # Change: #[cfg(target_os = "linux")] → #[cfg(all(target_os = "linux", feature = "linux-sandbox"))]
  sed -i 's|#\[cfg(target_os = "linux")\]|#[cfg(all(target_os = "linux", feature = "linux-sandbox"))]|g' $out/build/src/lib.rs $out/build/src/buildservice/mod.rs

  # Also gate imports of bwrap/oci in from_addr.rs
  chmod u+w $out/build/src/buildservice/from_addr.rs
  sed -i 's|use crate::buildservice::bwrap|#[cfg(feature = "linux-sandbox")] use crate::buildservice::bwrap|' $out/build/src/buildservice/from_addr.rs
  sed -i 's|use super::oci|#[cfg(feature = "linux-sandbox")] use super::oci|' $out/build/src/buildservice/from_addr.rs
  # Gate the match arms that use bwrap/oci
  sed -i '/"oci" =>/{s/^/        #[cfg(feature = "linux-sandbox")]\n/}' $out/build/src/buildservice/from_addr.rs
  sed -i '/"bwrap" =>/{s/^/        #[cfg(feature = "linux-sandbox")]\n/}' $out/build/src/buildservice/from_addr.rs

  # Disable cloud in snix-castore defaults (pulls bigtable_rs → tonic 0.14 → aws-lc).
  # Also disable tonic-reflection (unused on Redox).
  sed -i 's|default = \["cloud"\]|default = []|' $out/castore/Cargo.toml

  # Disable default features in snix-store (pulls cloud/bigtable, fuse, tonic-reflection).
  # Upstream dropped otlp from defaults between eee4779 and 2207a07; the new
  # default set is ["cloud", "fuse", "tonic-reflection"].
  sed -i 's|default = \["cloud", "fuse", "tonic-reflection"\]|default = []|' $out/store/Cargo.toml

  # NOTE: tonic tls-aws-lc → tls-ring override.
  # As of 2207a07, store/Cargo.toml uses `tonic.workspace = true` (no inline
  # features). The tls backend is controlled by the workspace [dependencies]
  # in snix-redox/Cargo.toml, where we set tls-ring. No sed needed here.

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

  # Make derivation_into_build_request public so snix-redox can use it.
  # Upstream keeps it pub(crate) because only snix-glue's own build
  # orchestration calls it. We need it in local_build.rs to convert
  # Derivation → BuildRequest for env var setup, refscan needles, etc.
  chmod -R u+w $out/glue
  sed -i 's|pub(crate) fn derivation_into_build_request|pub fn derivation_into_build_request|' $out/glue/src/builder/mod.rs

  # Make fetchurl module public so snix-redox can use fetchurl_derivation_to_fetch.
  sed -i 's|^mod fetchurl;|pub mod fetchurl;|' $out/glue/src/lib.rs
  sed -i 's|pub(crate) fn fetchurl_derivation_to_fetch|pub fn fetchurl_derivation_to_fetch|' $out/glue/src/fetchurl.rs
  sed -i 's|pub(crate) enum Error|pub enum Error|' $out/glue/src/fetchurl.rs

  chmod -R a-w $out/glue

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
