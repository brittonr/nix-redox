# serve-cache: Serve a Nix binary cache directory over HTTP
#
# Wraps Python's http.server to serve static files from a cache directory.
# The cache uses standard Nix binary cache format (narinfo + NARs) with
# flat layout (NARs in root, not nar/ subdirectory).
#
# Usage:
#   nix run .#serve-cache                          # Serve ./cache on port 18080
#   nix run .#serve-cache -- --port 9090           # Custom port
#   nix run .#serve-cache -- --dir /path/to/cache  # Custom directory
#   REDOX_SHARED_DIR=/tmp/shared nix run .#serve-cache  # Serve $REDOX_SHARED_DIR/cache

{
  pkgs,
  lib,
}:

pkgs.writeShellScriptBin "serve-cache" ''
  set -euo pipefail

  PORT="''${SERVE_CACHE_PORT:-18080}"
  DIR=""

  usage() {
    echo "Usage: serve-cache [OPTIONS]"
    echo ""
    echo "Serve a Nix binary cache directory over HTTP."
    echo ""
    echo "Options:"
    echo "  --port PORT    Port to listen on (default: 18080, env: SERVE_CACHE_PORT)"
    echo "  --dir DIR      Directory to serve (default: \$REDOX_SHARED_DIR/cache or ./cache)"
    echo "  --help         Show this help"
    echo ""
    echo "The directory should contain nix-cache-info, packages.json, .narinfo,"
    echo "and .nar.zst files in flat layout."
    exit 0
  }

  while [ $# -gt 0 ]; do
    case "$1" in
      --port) PORT="$2"; shift 2 ;;
      --dir)  DIR="$2"; shift 2 ;;
      --help) usage ;;
      *)      echo "Unknown option: $1"; usage ;;
    esac
  done

  # Determine cache directory
  if [ -z "$DIR" ]; then
    if [ -n "''${REDOX_SHARED_DIR:-}" ]; then
      DIR="$REDOX_SHARED_DIR/cache"
    else
      DIR="./cache"
    fi
  fi

  if [ ! -d "$DIR" ]; then
    echo "ERROR: Cache directory does not exist: $DIR"
    exit 1
  fi

  # Verify cache structure
  if [ ! -f "$DIR/nix-cache-info" ] && [ ! -f "$DIR/packages.json" ]; then
    echo "WARNING: Neither nix-cache-info nor packages.json found in $DIR"
    echo "         This may not be a valid binary cache directory."
    echo ""
  fi

  # Count cache contents
  NARINFO_COUNT=$(ls -1 "$DIR"/*.narinfo 2>/dev/null | wc -l)
  NAR_COUNT=$(ls -1 "$DIR"/*.nar.zst 2>/dev/null | wc -l)

  echo "serve-cache"
  echo "  Directory: $DIR"
  echo "  Port:      $PORT"
  echo "  Packages:  $NARINFO_COUNT narinfo, $NAR_COUNT NARs"
  echo ""
  echo "  URL: http://0.0.0.0:$PORT"
  echo "  Guest URL: http://10.0.2.2:$PORT (QEMU SLiRP)"
  echo ""
  echo "  Usage from Redox guest:"
  echo "    snix search --cache-url http://10.0.2.2:$PORT"
  echo "    snix install <pkg> --cache-url http://10.0.2.2:$PORT"
  echo ""
  echo "Press Ctrl+C to stop."
  echo ""

  exec ${pkgs.python3}/bin/python3 -m http.server "$PORT" \
    --directory "$DIR" \
    --bind 0.0.0.0
''
