# build-bridge: Host-side build daemon for in-guest `snix system rebuild --bridge`
#
# Architecture (snix BuildService pattern over virtio-fs shared directory):
#
#   Guest (Redox)                           Host (Linux)
#   ─────────────                           ────────────
#   snix system rebuild --bridge            build-bridge watches shared dir
#     │                                       ├── polls requests/*.json
#     ├─ writes config to /scheme/shared/ ─→  ├── translates config → adios overrides
#     │                                       ├── runs `nix build` via bridge-eval.nix
#     │                                       ├── exports packages to cache/ (NAR format)
#     │                                       └── writes responses/*.json with manifest
#     ├─ polls responses/*.json ←──────────
#     │
#     ├─ reads cache/*.narinfo ←───────────  (Nix binary cache format)
#     ├─ reads cache/*.nar.zst ←───────────
#     │
#     └─ installs + activates from store paths
#
# Channel: virtio-fs shared directory (host: $REDOX_SHARED_DIR, guest: /scheme/shared)
# Protocol: JSON files for requests/responses, Nix binary cache for outputs
# Build: bridge-eval.nix translates config → module overrides → rootTree

{
  pkgs,
  lib,
}:

let
  python = pkgs.python3;
  nix = pkgs.nix;
  buildBinaryCachePy = ../../lib/build-binary-cache.py;
  bridgeEvalNix = ../../lib/bridge-eval.nix;
in
pkgs.writeShellScriptBin "redox-build-bridge" ''
    set -euo pipefail

    SHARED_DIR="''${REDOX_SHARED_DIR:-/tmp/redox-shared}"
    FLAKE_DIR="''${REDOX_FLAKE_DIR:-$(pwd)}"
    PROFILE="''${REDOX_PROFILE:-default}"
    POLL_INTERVAL="''${POLL_INTERVAL:-1}"
    # Allow overriding nix binary (the pinned version may not have local cache)
    NIX_CMD="''${REDOX_NIX:-${nix}/bin/nix}"

    # Colors
    if [ -t 2 ]; then
      RED=$'\033[1;31m' GREEN=$'\033[1;32m' BLUE=$'\033[1;34m'
      YELLOW=$'\033[1;33m' BOLD=$'\033[1m' RESET=$'\033[0m'
    else
      RED="" GREEN="" BLUE="" YELLOW="" BOLD="" RESET=""
    fi

    mkdir -p "$SHARED_DIR"/{requests,responses,cache}

    echo -e "''${BOLD}redox-build-bridge''${RESET}"
    echo "  Shared:  $SHARED_DIR"
    echo "  Flake:   $FLAKE_DIR"
    echo "  Profile: $PROFILE"
    echo "  Bridge eval: ${bridgeEvalNix}"
    echo ""
    echo "Waiting for build requests..."

    process_request() {
      local req_file="$1"
      local req_id
      req_id=$(basename "$req_file" .json)
      local resp_file="$SHARED_DIR/responses/$req_id.json"
      local start_ms=$(( $(date +%s%N) / 1000000 ))

      echo -e "''${BLUE}[$(date +%H:%M:%S)] Processing: $req_id''${RESET}"

      # Extract the config field from the request JSON
      local config_file
      config_file=$(mktemp /tmp/bridge-config-XXXXXX.json)
      ${python}/bin/python3 -c "
  import json, sys
  with open('$req_file') as f:
      req = json.load(f)
  config = req.get('config', {})
  with open('$config_file', 'w') as f:
      json.dump(config, f, indent=2)
  print(f'  Config: {json.dumps(config)[:200]}...' if len(json.dumps(config)) > 200 else f'  Config: {json.dumps(config)}')
  "

      # Build using bridge-eval.nix
      echo -e "  ''${BLUE}Building with nix...''${RESET}"
      local build_output root_tree
      if build_output=$($NIX_CMD build \
        --file "${bridgeEvalNix}" \
        --arg flakeDir "\"$FLAKE_DIR\"" \
        --arg configPath "\"$config_file\"" \
        --arg profile "\"$PROFILE\"" \
        --no-link --print-out-paths --impure 2>&1); then

        root_tree=$(echo "$build_output" | tail -1)
        echo -e "  ''${GREEN}Build OK: $root_tree''${RESET}"

        # Read the manifest from the built rootTree
        local manifest_path="$root_tree/etc/redox-system/manifest.json"
        if [ ! -f "$manifest_path" ]; then
          echo -e "  ''${RED}ERROR: manifest not found in rootTree''${RESET}"
          write_error_response "$resp_file" "$req_id" "manifest not found in rootTree"
          cleanup_request "$req_file" "$req_id" "$config_file"
          return
        fi

        # Export packages to shared binary cache
        echo -e "  ''${BLUE}Exporting packages to cache...''${RESET}"
        export_packages_to_cache "$root_tree" "$manifest_path"

        # Calculate build time
        local end_ms=$(( $(date +%s%N) / 1000000 ))
        local build_time_ms=$(( end_ms - start_ms ))

        # Write success response with the manifest
        ${python}/bin/python3 -c "
  import json
  with open('$manifest_path') as f:
      manifest = json.load(f)
  response = {
      'status': 'success',
      'requestId': '$req_id',
      'manifest': manifest,
      'buildTimeMs': $build_time_ms
  }
  with open('$resp_file', 'w') as f:
      json.dump(response, f, indent=2)
  print(f'  Packages: {len(manifest.get(\"packages\", []))}')
  "
        echo -e "  ''${GREEN}Response written (''${build_time_ms}ms)''${RESET}"
      else
        echo -e "  ''${RED}Build failed''${RESET}"
        local error_msg
        error_msg=$(echo "$build_output" | head -20)
        write_error_response "$resp_file" "$req_id" "$error_msg"
      fi

      cleanup_request "$req_file" "$req_id" "$config_file"
    }

    write_error_response() {
      local resp_file="$1" req_id="$2" error_msg="$3"
      # Write error message to a temp file to avoid shell/Python quoting issues
      # (Nix error output contains Unicode like '…' which breaks Python string literals)
      local err_tmp
      err_tmp=$(mktemp /tmp/bridge-errmsg-XXXXXX.txt)
      printf '%s' "$error_msg" > "$err_tmp"
      ${python}/bin/python3 -c "
  import json
  with open('$err_tmp') as f:
      error_msg = f.read()
  response = {
      'status': 'error',
      'requestId': '$req_id',
      'error': error_msg
  }
  with open('$resp_file', 'w') as f:
      json.dump(response, f, indent=2)
  "
      rm -f "$err_tmp"
    }

    cleanup_request() {
      local req_file="$1" req_id="$2" config_file="$3"
      mv "$req_file" "$SHARED_DIR/requests/.$req_id.done" 2>/dev/null || true
      rm -f "$config_file"
      rm -f "$req_file.lock"
    }

    export_packages_to_cache() {
      local root_tree="$1" manifest_path="$2"

      # Extract package store paths from the manifest and serialize to cache
      local pkg_info
      pkg_info=$(mktemp /tmp/bridge-pkginfo-XXXXXX.json)
      local cache_tmp
      cache_tmp=$(mktemp -d /tmp/bridge-cache-XXXXXX)

      # Generate package-info.json from the manifest's package list + boot components
      ${python}/bin/python3 -c "
  import json, os
  with open('$manifest_path') as f:
      manifest = json.load(f)
  entries = []
  for pkg in manifest.get('packages', []):
      sp = pkg.get('storePath', str())
      if sp and os.path.exists(sp):
          entries.append({
              'name': pkg.get('name', str()),
              'storePath': sp,
              'pname': pkg.get('name', str()),
              'version': pkg.get('version', str()),
          })
      else:
          print(f'  Skipping {pkg.get(\"name\",\"?\")} (store path missing: {sp})')
  # Export boot component store paths (v2 manifests)
  boot = manifest.get('boot', {})
  for comp_name, file_path in [('kernel', boot.get('kernel')), ('initfs', boot.get('initfs')), ('bootloader', boot.get('bootloader'))]:
      if not file_path:
          continue
      # Extract store dir from file path: /nix/store/abc-kernel/boot/kernel -> /nix/store/abc-kernel
      parts = file_path.split('/')
      if len(parts) >= 4 and parts[1] == 'nix' and parts[2] == 'store':
          store_dir = '/'.join(parts[:4])
          if os.path.exists(store_dir):
              entries.append({
                  'name': comp_name,
                  'storePath': store_dir,
                  'pname': comp_name,
                  'version': 'boot',
              })
              print(f'  Boot component: {comp_name} -> {store_dir}')
          else:
              print(f'  Skipping boot {comp_name} (store path missing: {store_dir})')
  with open('$pkg_info', 'w') as f:
      json.dump(entries, f, indent=2)
  print(f'  {len(entries)} entries to export (packages + boot)')
  "

      # Run the binary cache builder
      ${python}/bin/python3 ${buildBinaryCachePy} "$pkg_info" "$cache_tmp" 2>&1 | sed 's/^/    /'

      # Merge into the shared cache (flatten nar/ subdirectory)
      ${python}/bin/python3 -c "
  import json, os, shutil

  src = '$cache_tmp'
  dst = '$SHARED_DIR/cache'

  # Copy narinfo files, rewriting URL to flatten nar/ subdirectory
  for f in os.listdir(src):
      if f.endswith('.narinfo'):
          with open(os.path.join(src, f)) as fh:
              content = fh.read()
          content = content.replace('URL: nar/', 'URL: ')
          with open(os.path.join(dst, f), 'w') as fh:
              fh.write(content)

  # Copy NAR files to cache root (flat layout)
  src_nar = os.path.join(src, 'nar')
  if os.path.isdir(src_nar):
      for f in os.listdir(src_nar):
          shutil.copy2(os.path.join(src_nar, f), os.path.join(dst, f))

  # Merge packages.json
  src_idx = {}
  src_idx_path = os.path.join(src, 'packages.json')
  if os.path.exists(src_idx_path):
      with open(src_idx_path) as f:
          src_idx = json.load(f)

  dst_idx = {'version': 1, 'packages': {}}
  dst_idx_path = os.path.join(dst, 'packages.json')
  if os.path.exists(dst_idx_path):
      with open(dst_idx_path) as f:
          dst_idx = json.load(f)

  new_pkgs = src_idx.get('packages', {})
  dst_idx['packages'].update(new_pkgs)

  with open(dst_idx_path, 'w') as f:
      json.dump(dst_idx, f, indent=2, sort_keys=True)

  # Ensure nix-cache-info exists
  cache_info = os.path.join(dst, 'nix-cache-info')
  if not os.path.exists(cache_info):
      with open(cache_info, 'w') as f:
          f.write('StoreDir: /nix/store\n')

  # Make files readable by virtiofsd
  for root, dirs, files in os.walk(dst):
      for d in dirs:
          os.chmod(os.path.join(root, d), 0o755)
      for f in files:
          os.chmod(os.path.join(root, f), 0o644)

  print(f'  Merged {len(new_pkgs)} packages into shared cache')
  "

      rm -rf "$cache_tmp" "$pkg_info"
    }

    # ── Derivation-Level Build Handlers ────────────────────────────────
    #
    # Handle "build-attr" and "build-drv" requests from snix build --bridge

    process_build_request() {
      local req_file="$1"
      local req_id
      req_id=$(basename "$req_file" .json)
      local resp_file="$SHARED_DIR/responses/$req_id.json"
      local start_ms=$(( $(date +%s%N) / 1000000 ))
      local req_type

      req_type=$(${python}/bin/python3 -c "
    import json
    with open('$req_file') as f:
        req = json.load(f)
    print(req.get('type', 'unknown'))
    ")

      case "$req_type" in
        build-attr)
          local attr
          attr=$(${python}/bin/python3 -c "
    import json
    with open('$req_file') as f:
        print(json.load(f).get('attr', str()))
    ")
          echo -e "''${BLUE}[$(date +%H:%M:%S)] Build-attr: $attr (req: $req_id)''${RESET}"

          local out_path
          if out_path=$($NIX_CMD build "$FLAKE_DIR#$attr" --no-link --print-out-paths 2>&1); then
            out_path=$(echo "$out_path" | tail -1)
            echo -e "  ''${GREEN}Built: $out_path''${RESET}"

            # Export output to shared cache
            export_single_output "$attr" "$out_path"

            local end_ms=$(( $(date +%s%N) / 1000000 ))
            local build_time_ms=$(( end_ms - start_ms ))

            ${python}/bin/python3 -c "
    import json
    response = {
        'status': 'success',
        'requestId': '$req_id',
        'outputs': {'out': '$out_path'},
        'buildTimeMs': $build_time_ms
    }
    with open('$resp_file', 'w') as f:
        json.dump(response, f, indent=2)
    "
            echo -e "  ''${GREEN}Response written (''${build_time_ms}ms)''${RESET}"
          else
            echo -e "  ''${RED}Build failed''${RESET}"
            write_build_error_response "$resp_file" "$req_id" "$out_path"
          fi
          ;;

        build-drv)
          echo -e "''${BLUE}[$(date +%H:%M:%S)] Build-drv: $req_id''${RESET}"

          # Extract ATerm and write to temp .drv file
          local drv_info
          drv_info=$(${python}/bin/python3 -c "
    import json, sys
    with open('$req_file') as f:
        req = json.load(f)
    aterm = req.get('drvAterm', str())
    name = req.get('drvName', 'unknown')
    outputs = req.get('expectedOutputs', {})
    if not aterm:
        print('ERROR:no ATerm in request', file=sys.stderr)
        sys.exit(1)
    # Write ATerm to temp file
    import tempfile
    drv_file = tempfile.mktemp(suffix='.drv', prefix='bridge-')
    with open(drv_file, 'w') as f:
        f.write(aterm)
    print(f'{drv_file}')
    print(f'{name}')
    for out_name, out_path in outputs.items():
        print(f'{out_name}={out_path}')
    ")

          local drv_file drv_name
          drv_file=$(echo "$drv_info" | head -1)
          drv_name=$(echo "$drv_info" | sed -n '2p')

          if [ -z "$drv_file" ] || [ ! -f "$drv_file" ]; then
            write_build_error_response "$resp_file" "$req_id" "failed to extract derivation"
            cleanup_request "$req_file" "$req_id" ""
            return
          fi

          echo -e "  Derivation: $drv_name ($drv_file)"

          # Import .drv into Nix store and build
          local store_drv
          if store_drv=$($NIX_CMD-store --add "$drv_file" 2>&1); then
            echo -e "  Imported: $store_drv"

            local out_path
            if out_path=$($NIX_CMD-store --realise "$store_drv" 2>&1); then
              echo -e "  ''${GREEN}Built: $out_path''${RESET}"

              # Export output to shared cache
              export_single_output "$drv_name" "$out_path"

              local end_ms=$(( $(date +%s%N) / 1000000 ))
              local build_time_ms=$(( end_ms - start_ms ))

              # Build outputs map from expected outputs
              ${python}/bin/python3 -c "
    import json
    with open('$req_file') as f:
        req = json.load(f)
    expected = req.get('expectedOutputs', {})
    # If we have expected outputs, use those; otherwise use realised path
    outputs = expected if expected else {'out': '$out_path'}
    response = {
        'status': 'success',
        'requestId': '$req_id',
        'outputs': outputs,
        'buildTimeMs': $build_time_ms
    }
    with open('$resp_file', 'w') as f:
        json.dump(response, f, indent=2)
    "
              echo -e "  ''${GREEN}Response written (''${build_time_ms}ms)''${RESET}"
            else
              echo -e "  ''${RED}Realise failed''${RESET}"
              write_build_error_response "$resp_file" "$req_id" "$out_path"
            fi
          else
            echo -e "  ''${RED}Import failed''${RESET}"
            write_build_error_response "$resp_file" "$req_id" "$store_drv"
          fi

          rm -f "$drv_file"
          ;;

        *)
          echo -e "''${YELLOW}Unknown request type: $req_type''${RESET}"
          write_build_error_response "$resp_file" "$req_id" "unknown request type: $req_type"
          ;;
      esac

      cleanup_request "$req_file" "$req_id" ""
    }

    write_build_error_response() {
      local resp_file="$1" req_id="$2" error_msg="$3"
      local err_tmp
      err_tmp=$(mktemp /tmp/bridge-build-err-XXXXXX.txt)
      printf '%s' "$error_msg" > "$err_tmp"
      ${python}/bin/python3 -c "
    import json
    with open('$err_tmp') as f:
        error_msg = f.read()
    response = {
        'status': 'error',
        'requestId': '$req_id',
        'error': error_msg
    }
    with open('$resp_file', 'w') as f:
        json.dump(response, f, indent=2)
    "
      rm -f "$err_tmp"
    }

    export_single_output() {
      local name="$1" store_path="$2"

      if [ ! -e "$store_path" ]; then
        echo -e "  ''${YELLOW}Warning: output missing: $store_path''${RESET}"
        return
      fi

      local pkg_info cache_tmp
      pkg_info=$(mktemp /tmp/bridge-build-pkg-XXXXXX.json)
      cache_tmp=$(mktemp -d /tmp/bridge-build-cache-XXXXXX)

      local version
      version=$(echo "$store_path" | sed 's|.*/||; s|^[^-]*-||; s|-[^-]*$||')

      ${python}/bin/python3 -c "
    import json
    entries = [{
        'name': '$name',
        'storePath': '$store_path',
        'pname': '$name',
        'version': '$version',
    }]
    with open('$pkg_info', 'w') as f:
        json.dump(entries, f)
    "

      ${python}/bin/python3 ${buildBinaryCachePy} "$pkg_info" "$cache_tmp" 2>&1 | sed 's/^/    /'

      # Merge into shared cache (same logic as export_packages_to_cache)
      ${python}/bin/python3 -c "
    import json, os, shutil
    src, dst = '$cache_tmp', '$SHARED_DIR/cache'
    os.makedirs(dst, exist_ok=True)
    for f in os.listdir(src):
        if f.endswith('.narinfo'):
            with open(os.path.join(src, f)) as fh:
                content = fh.read().replace('URL: nar/', 'URL: ')
            with open(os.path.join(dst, f), 'w') as fh:
                fh.write(content)
    src_nar = os.path.join(src, 'nar')
    if os.path.isdir(src_nar):
        for f in os.listdir(src_nar):
            shutil.copy2(os.path.join(src_nar, f), os.path.join(dst, f))
    dst_idx = {'version': 1, 'packages': {}}
    dst_idx_path = os.path.join(dst, 'packages.json')
    if os.path.exists(dst_idx_path):
        with open(dst_idx_path) as f:
            dst_idx = json.load(f)
    src_idx_path = os.path.join(src, 'packages.json')
    if os.path.exists(src_idx_path):
        with open(src_idx_path) as f:
            dst_idx['packages'].update(json.load(f).get('packages', {}))
    with open(dst_idx_path, 'w') as f:
        json.dump(dst_idx, f, indent=2, sort_keys=True)
    ci = os.path.join(dst, 'nix-cache-info')
    if not os.path.exists(ci):
        with open(ci, 'w') as f: f.write('StoreDir: /nix/store\n')
    for r, ds, fs_ in os.walk(dst):
        for d in ds: os.chmod(os.path.join(r, d), 0o755)
        for f in fs_: os.chmod(os.path.join(r, f), 0o644)
    "

      rm -rf "$cache_tmp" "$pkg_info"
    }

    # Main loop: poll for requests
    while true; do
      for req_file in "$SHARED_DIR"/requests/*.json; do
        [ -f "$req_file" ] || continue
        [ -f "$req_file.lock" ] && continue
        touch "$req_file.lock"

        # Route to appropriate handler based on filename prefix
        basename=$(basename "$req_file" .json)
        case "$basename" in
          build-*)
            process_build_request "$req_file"
            ;;
          rebuild-*)
            process_request "$req_file"
            ;;
          *)
            process_request "$req_file"
            ;;
        esac
      done
      sleep "$POLL_INTERVAL"
    done
''
