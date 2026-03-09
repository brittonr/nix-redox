# Build a small test binary cache for network install testing.
#
# Creates a binary cache directory with:
#   packages.json        — package index
#   {hash}.narinfo       — per-path metadata
#   nar/{hash}.nar.zst   — compressed NAR files
#
# Contains a mock "mock-hello" package — a simple shell script.
# Exercises the full NAR/narinfo pipeline that snix consumes.

{
  pkgs,
  lib,
}:

let
  buildBinaryCachePy = ../../lib/build-binary-cache.py;

  # Build a small mock package for the test cache.
  mockHello = pkgs.runCommand "mock-hello-1.0" { } ''
    mkdir -p $out/bin
    cat > $out/bin/mock-hello << 'SCRIPT'
    #!/bin/sh
    echo "Hello from network-installed mock-hello!"
    SCRIPT
    chmod +x $out/bin/mock-hello
  '';

  # Package info JSON consumed by build-binary-cache.py
  packageInfo = pkgs.writeText "test-package-info.json" (
    builtins.toJSON [
      {
        name = "mock-hello";
        storePath = builtins.unsafeDiscardStringContext "${mockHello}";
        pname = "mock-hello";
        version = "1.0";
      }
    ]
  );
in
pkgs.runCommand "test-binary-cache"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.zstd
    ];
    # Make mockHello available in sandbox
    inherit mockHello;
  }
  ''
    mkdir -p $out

    # Copy the mock package to a temp location so the builder can read it
    # (Nix store paths are readable in the sandbox)

    ${pkgs.python3}/bin/python3 ${buildBinaryCachePy} \
      ${packageInfo} \
      "$out"

    # The builder puts NARs in nar/ subdir. For our flat cache layout
    # (matching what snix expects with the bridge), move NARs to root.
    if [ -d "$out/nar" ]; then
      for f in "$out/nar"/*; do
        mv "$f" "$out/"
      done
      rmdir "$out/nar"

      # Rewrite narinfo URL fields from "nar/hash.nar.zst" to "hash.nar.zst"
      for ni in "$out"/*.narinfo; do
        ${pkgs.gnused}/bin/sed -i 's|^URL: nar/|URL: |' "$ni"
      done
    fi

    # Verify the cache structure
    test -f "$out/packages.json" || (echo "ERROR: packages.json missing"; exit 1)
    test -f "$out/nix-cache-info" || (echo "ERROR: nix-cache-info missing"; exit 1)

    echo ""
    echo "Test binary cache built:"
    echo "  packages: $(${pkgs.python3}/bin/python3 -c "import json; d=json.load(open('$out/packages.json')); print(len(d['packages']))")"
    echo "  size:     $(du -sh "$out" | cut -f1)"
  ''
