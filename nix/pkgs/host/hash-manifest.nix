# hash-manifest: BLAKE3 manifest hasher for RedoxOS rootTree
#
# Host-only build tool used by the rootTree derivation.
# Replaces the inline Python BLAKE3 manifest hasher.

{ pkgs }:

pkgs.rustPlatform.buildRustPackage {
  pname = "hash-manifest";
  version = "0.1.0";
  src = ./hash-manifest;
  cargoLock.lockFile = ./hash-manifest/Cargo.lock;
}
