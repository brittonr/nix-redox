# Build a test channel cache for channel update testing.
#
# Produces a directory that serves as both:
#   1. A channel endpoint (manifest.json in system manifest format)
#   2. A binary cache (narinfo + NARs for new packages)
#
# The channel manifest is a copy of the system's manifest with one extra
# package (mock-hello) added. This lets `snix system upgrade` detect a
# diff and fetch the new package from the cache.

{
  pkgs,
  lib,
  # The system's root tree (contains /etc/redox-system/manifest.json)
  rootTree,
  # The test binary cache (reuse from test-binary-cache.nix)
  testBinaryCache,
}:

let
  # The mock-hello store path as it appears in the test binary cache.
  # We read it from the cache's packages.json at build time.
  #
  # Build a channel manifest that includes everything from the system
  # manifest plus the mock-hello package from the test cache.
  buildChannelCache = pkgs.writeText "build-channel-cache.py" ''
    import json
    import os
    import shutil
    import sys

    base_manifest_path = sys.argv[1]
    test_cache_dir = sys.argv[2]
    out_dir = sys.argv[3]

    # Copy the entire test binary cache (narinfo + NARs + packages.json)
    for entry in os.listdir(test_cache_dir):
        src = os.path.join(test_cache_dir, entry)
        dst = os.path.join(out_dir, entry)
        if os.path.isdir(src):
            shutil.copytree(src, dst)
        else:
            shutil.copy2(src, dst)

    # Load the base system manifest
    with open(base_manifest_path) as f:
        manifest = json.load(f)

    # Load the test cache package index to get mock-hello's store path
    with open(os.path.join(test_cache_dir, "packages.json")) as f:
        cache_index = json.load(f)

    mock_hello = cache_index["packages"].get("mock-hello")
    if not mock_hello:
        print("ERROR: mock-hello not found in test cache", file=sys.stderr)
        sys.exit(1)

    # Add mock-hello to the manifest's packages list
    manifest["packages"].append({
        "name": "mock-hello",
        "version": mock_hello.get("version", "1.0"),
        "storePath": mock_hello["storePath"],
    })

    # Bump the version so the upgrade shows a version change
    manifest["system"]["redoxSystemVersion"] = (
        manifest["system"].get("redoxSystemVersion", "0.0.0") + "-channel-1"
    )

    # Clear the build hash so the upgrade doesn't short-circuit
    # on hash comparison (the plan diff will detect the new package)
    manifest["generation"]["buildHash"] = "channel-updated"

    # Write the channel manifest
    with open(os.path.join(out_dir, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)

    print(f"Channel manifest: {len(manifest['packages'])} packages "
          f"(+1 mock-hello)", file=sys.stderr)
  '';

  baseManifestJson = "${rootTree}/etc/redox-system/manifest.json";
in

pkgs.runCommand "channel-update-cache"
  {
    nativeBuildInputs = [ pkgs.python3 ];
  }
  ''
    mkdir -p $out

    ${pkgs.python3}/bin/python3 ${buildChannelCache} \
      ${baseManifestJson} \
      ${testBinaryCache} \
      $out

    # Verify
    test -f "$out/manifest.json" || (echo "ERROR: manifest.json missing"; exit 1)
    test -f "$out/packages.json" || (echo "ERROR: packages.json missing"; exit 1)
    test -f "$out/nix-cache-info" || (echo "ERROR: nix-cache-info missing"; exit 1)

    echo ""
    echo "Channel update cache built:"
    echo "  manifest packages: $(${pkgs.python3}/bin/python3 -c "import json; d=json.load(open('$out/manifest.json')); print(len(d['packages']))")"
    echo "  cache packages:    $(${pkgs.python3}/bin/python3 -c "import json; d=json.load(open('$out/packages.json')); print(len(d['packages']))")"
    echo "  size:              $(du -sh "$out" | cut -f1)"
  ''
