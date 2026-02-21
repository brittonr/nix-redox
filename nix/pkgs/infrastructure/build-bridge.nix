# build-bridge: Host-side build daemon for in-guest `snix system rebuild`
#
# Architecture (snix BuildService pattern over virtio-fs shared directory):
#
#   Guest (Redox)                           Host (Linux)
#   ─────────────                           ────────────
#   snix-eval evaluates adios               build-bridge watches shared dir
#   module system in-guest                    ├── polls requests/*.json
#     │                                       ├── runs `nix build` with overrides
#     ├─ writes config to /scheme/shared/ ─→  ├── exports NARs to cache/
#     │                                       └── writes responses/*.json
#     ├─ polls responses/*.json ←──────────
#     │
#     ├─ reads cache/*.narinfo ←───────────  (Nix binary cache format)
#     ├─ reads cache/nar/*.nar.zst ←───────
#     │
#     └─ activates from store paths
#
# Channel: virtio-fs shared directory (host: $REDOX_SHARED_DIR, guest: /scheme/shared)
# Protocol: JSON files for requests/responses, Nix binary cache for outputs
# Build: `nix build` with config overrides applied to the flake

{ pkgs, lib }:

pkgs.writeShellScriptBin "redox-build-bridge" ''
    set -euo pipefail

    SHARED_DIR="''${REDOX_SHARED_DIR:-/tmp/redox-shared}"
    FLAKE_DIR="''${REDOX_FLAKE_DIR:-$(pwd)}"
    PROFILE="''${REDOX_PROFILE:-default}"
    POLL_INTERVAL="''${POLL_INTERVAL:-1}"

    # Colors
    if [ -t 2 ]; then
      RED=$'\033[1;31m' GREEN=$'\033[1;32m' BLUE=$'\033[1;34m'
      BOLD=$'\033[1m' RESET=$'\033[0m'
    else
      RED="" GREEN="" BLUE="" BOLD="" RESET=""
    fi

    mkdir -p "$SHARED_DIR"/{requests,responses,cache}

    echo -e "''${BOLD}redox-build-bridge''${RESET}"
    echo "  Shared: $SHARED_DIR"
    echo "  Flake:  $FLAKE_DIR"
    echo "  Profile: $PROFILE"
    echo ""
    echo "Waiting for build requests..."

    process_request() {
      local req_file="$1"
      local req_id
      req_id=$(basename "$req_file" .json)
      local resp_file="$SHARED_DIR/responses/$req_id.json"

      echo -e "''${BLUE}[$(date +%H:%M:%S)] Building: $req_id''${RESET}"

      # Write a Nix expression that applies the config overrides from the request
      local tmp_expr
      tmp_expr=$(mktemp /tmp/redox-build-XXXXXX.nix)

      cat > "$tmp_expr" << NIXEOF
      let
        flake = builtins.getFlake "$FLAKE_DIR";
        system = builtins.currentSystem;
        lp = flake.legacyPackages.\''${system};
        overrides = builtins.fromJSON (builtins.readFile "$req_file");
        newSystem = lp.redoxConfigurations.$PROFILE.extend overrides;
      in newSystem.rootTree
      NIXEOF

      local build_output root_tree
      if build_output=$(${pkgs.nix}/bin/nix build \
        --file "$tmp_expr" \
        --no-link --print-out-paths --impure 2>&1); then

        root_tree=$(echo "$build_output" | tail -1)
        echo -e "  ''${GREEN}Build OK: $root_tree''${RESET}"

        # Export to binary cache
        ${pkgs.nix}/bin/nix copy \
          --to "file://$SHARED_DIR/cache" \
          "$root_tree" 2>/dev/null || true

        local narinfo_count
        narinfo_count=$(find "$SHARED_DIR/cache" -name '*.narinfo' | wc -l)
        echo "  Cache: $narinfo_count paths"

        # Write success response
        ${pkgs.python3}/bin/python3 -c "
  import json, os
  root_tree = '$root_tree'
  manifest = None
  mp = os.path.join(root_tree, 'etc/redox-system/manifest.json')
  if os.path.exists(mp):
      with open(mp) as f: manifest = json.load(f)
  with open('$resp_file', 'w') as f:
      json.dump({'status':'success','requestId':'$req_id','rootTree':root_tree,'manifest':manifest}, f, indent=2)
  "
        echo -e "  ''${GREEN}Done''${RESET}"
      else
        echo -e "  ''${RED}Build failed''${RESET}"
        ${pkgs.python3}/bin/python3 -c "
  import json
  with open('$resp_file', 'w') as f:
      json.dump({'status':'error','requestId':'$req_id','error':'''$(echo "$build_output" | head -20)'''}, f, indent=2)
  "
      fi

      mv "$req_file" "$SHARED_DIR/requests/.$req_id.done"
      rm -f "$tmp_expr"
    }

    while true; do
      for req_file in "$SHARED_DIR"/requests/*.json; do
        [ -f "$req_file" ] || continue
        [ -f "$req_file.lock" ] && continue
        touch "$req_file.lock"
        process_request "$req_file"
        rm -f "$req_file.lock"
      done
      sleep "$POLL_INTERVAL"
    done
''
