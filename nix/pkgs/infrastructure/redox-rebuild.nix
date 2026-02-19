# redox-rebuild: System configuration manager for RedoxOS
#
# Modeled after darwin-rebuild (bash CLI) and nixos-rebuild-ng (Python CLI).
# Since Redox runs in a VM managed from the host, this tool coordinates
# building configurations, managing generations, and launching VMs.
#
# Key differences from nixos-rebuild:
#   - No activation inside the target (Redox has no Nix store)
#   - No switch-to-configuration (no live service management yet)
#   - VM lifecycle management (Cloud Hypervisor / QEMU)
#   - Generation tracking is local to the project (.redox-generations/)
#
# Inspired by:
#   - NixOS: generation profiles, toplevel concept, build/switch/test actions
#   - NixBSD: composable disk images, FreeBSD rc.d service diffing
#   - nix-darwin: host-side rebuild, assertions/checks, changelog
#
# Usage:
#   nix run .#redox-rebuild -- build
#   nix run .#redox-rebuild -- run graphical
#   nix run .#redox-rebuild -- diff
#   nix run .#redox-rebuild -- list-generations --json

{ pkgs, lib }:

pkgs.writeShellScriptBin "redox-rebuild" ''
    set -euo pipefail

    # === Configuration ===
    GEN_DIR="''${REDOX_GENERATIONS:-.redox-generations}"
    PROFILE="default"
    FLAKE="."
    VERBOSE=0
    SHOW_TRACE=0
    JSON=0
    ACTION=""
    EXTRA_ARGS=()

    # === Colors (only if terminal) ===
    if [ -t 2 ]; then
      RED=$'\033[1;31m'
      GREEN=$'\033[1;32m'
      YELLOW=$'\033[1;33m'
      BLUE=$'\033[1;34m'
      BOLD=$'\033[1m'
      RESET=$'\033[0m'
    else
      RED="" GREEN="" YELLOW="" BLUE="" BOLD="" RESET=""
    fi

    # === Usage ===
    usage() {
      cat >&2 <<EOF
  ''${BOLD}redox-rebuild''${RESET} — RedoxOS system configuration manager

  ''${BOLD}USAGE:''${RESET}
      redox-rebuild <action> [profile] [options]

  ''${BOLD}ACTIONS:''${RESET}
      build [PROFILE]        Build the system toplevel derivation
      run [PROFILE]          Build disk image and launch VM
      test [PROFILE]         Build and run automated boot test
      diff [PROFILE]         Show what changed vs current generation
      check [PROFILE]        Run assertions and system checks only
      list-generations       List previous system builds
      rollback [GEN]         Switch to a previous generation number
      repl                   Open nix repl with system configuration
      edit                   Open flake.nix in \$EDITOR
      changelog              Show recent module system changes
      version                Show current system version info

  ''${BOLD}PROFILES:''${RESET}
      default                Development profile (networking, CLI tools)
      minimal                Minimal (ion + uutils only)
      graphical              Orbital desktop + audio
      cloud                  Cloud Hypervisor optimized (static IP)

  ''${BOLD}OPTIONS:''${RESET}
      --flake PATH           Flake path (default: .)
      --profile-name, -p N   Profile name (default: system)
      --verbose, -v          Show nix build output
      --show-trace           Pass --show-trace to nix
      --json                 JSON output (list-generations, version)
      --help, -h             Show this help

  ''${BOLD}EXAMPLES:''${RESET}
      redox-rebuild build                 # Build default profile
      redox-rebuild build minimal         # Build minimal profile
      redox-rebuild run graphical         # Run graphical desktop in QEMU
      redox-rebuild diff                  # Compare current vs new build
      redox-rebuild list-generations      # Show build history
      redox-rebuild rollback              # Revert to previous generation
      redox-rebuild test -- --verbose     # Boot test with verbose output

  ''${BOLD}ENVIRONMENT:''${RESET}
      REDOX_GENERATIONS      Override generation directory (default: .redox-generations)
      EDITOR                 Editor for 'edit' action (default: vi)
  EOF
      exit 0
    }

    # === Argument Parsing ===
    while [ $# -gt 0 ]; do
      case "$1" in
        build|run|test|diff|check|list-generations|rollback|repl|edit|changelog|version)
          ACTION="$1"
          shift
          # Next positional arg (if not an option) is the profile or gen number
          if [ $# -gt 0 ] && [[ ! "$1" =~ ^- ]]; then
            case "$ACTION" in
              rollback)
                EXTRA_ARGS+=("$1")
                shift
                ;;
              list-generations|repl|edit|changelog|version)
                ;; # these don't take a positional
              *)
                PROFILE="$1"
                shift
                ;;
            esac
          fi
          ;;
        --flake)
          FLAKE="$2"
          shift 2
          ;;
        --profile-name|-p)
          PROFILE="$2"
          shift 2
          ;;
        --verbose|-v)
          VERBOSE=1
          shift
          ;;
        --show-trace)
          SHOW_TRACE=1
          shift
          ;;
        --json)
          JSON=1
          shift
          ;;
        --help|-h)
          usage
          ;;
        --)
          shift
          EXTRA_ARGS+=("$@")
          break
          ;;
        *)
          echo -e "''${RED}error: unknown option '$1'$RESET" >&2
          echo "Run 'redox-rebuild --help' for usage." >&2
          exit 1
          ;;
      esac
    done

    if [ -z "$ACTION" ]; then
      usage
    fi

    # === Build Flags ===
    BUILD_FLAGS=()
    if [ "$VERBOSE" = "1" ]; then
      BUILD_FLAGS+=("--print-build-logs")
    fi
    if [ "$SHOW_TRACE" = "1" ]; then
      BUILD_FLAGS+=("--show-trace")
    fi

    # === Profile → Flake Attr Mapping ===
    resolve_toplevel_attr() {
      echo "redox-''${PROFILE}-toplevel"
    }

    resolve_diskimage_attr() {
      echo "redox-''${PROFILE}"
    }

    resolve_runner_attr() {
      case "$PROFILE" in
        default)   echo "run-redox-default" ;;
        minimal)   echo "run-redox-minimal" ;;
        graphical) echo "run-redox-graphical-desktop" ;;
        cloud)     echo "run-redox-cloud" ;;
        *)         echo "run-redox-''${PROFILE}" ;;
      esac
    }

    # === Resolve flake path for repl ===
    resolve_flake_path() {
      local p
      p=$(cd "$FLAKE" 2>/dev/null && pwd)
      echo "$p"
    }

    # === Generation Management ===
    next_generation_number() {
      local max_gen=0
      if [ -d "$GEN_DIR" ]; then
        for link in "$GEN_DIR"/system-*-link; do
          [ -e "$link" ] || continue
          local num
          num=$(basename "$link" | ${pkgs.gnused}/bin/sed 's/system-\([0-9]*\)-link/\1/')
          if [ "$num" -gt "$max_gen" ]; then
            max_gen="$num"
          fi
        done
      fi
      echo $((max_gen + 1))
    }

    current_generation_path() {
      if [ -L "$GEN_DIR/system" ]; then
        readlink -f "$GEN_DIR/system"
      else
        echo ""
      fi
    }

    update_generation() {
      local toplevel="$1"
      mkdir -p "$GEN_DIR"

      # Check if unchanged
      local current
      current=$(current_generation_path)
      if [ -n "$current" ] && [ "$current" = "$toplevel" ]; then
        echo -e "''${YELLOW}No change from current generation.''${RESET}"
        return 0
      fi

      # Create new generation
      local next_gen
      next_gen=$(next_generation_number)
      ln -sfn "$toplevel" "$GEN_DIR/system-''${next_gen}-link"
      ln -sfn "$toplevel" "$GEN_DIR/system"

      echo -e "''${GREEN}Generation $next_gen created.''${RESET}"
      echo "  $toplevel"
    }

    # === Actions ===

    do_build() {
      local attr
      attr=$(resolve_toplevel_attr)
      echo -e "''${BLUE}Building system configuration (profile: $PROFILE)...''${RESET}" >&2

      local toplevel
      toplevel=$(${pkgs.nix}/bin/nix build "''${FLAKE}#''${attr}" \
        --no-link --print-out-paths "''${BUILD_FLAGS[@]}" 2>&1 | tail -1)

      if [ ! -d "$toplevel" ]; then
        echo -e "''${RED}Build failed.''${RESET}" >&2
        exit 1
      fi

      echo -e "''${GREEN}Done.''${RESET} The system configuration is:" >&2
      echo "  $toplevel" >&2
      update_generation "$toplevel"
      echo "$toplevel"
    }

    do_run() {
      local runner
      runner=$(resolve_runner_attr)
      echo -e "''${BLUE}Building and running (profile: $PROFILE)...''${RESET}" >&2

      # Build toplevel first to track the generation
      local attr
      attr=$(resolve_toplevel_attr)
      local toplevel
      toplevel=$(${pkgs.nix}/bin/nix build "''${FLAKE}#''${attr}" \
        --no-link --print-out-paths "''${BUILD_FLAGS[@]}" 2>&1 | tail -1)

      if [ -d "$toplevel" ]; then
        update_generation "$toplevel"
      fi

      echo -e "''${BLUE}Launching VM...''${RESET}" >&2
      exec ${pkgs.nix}/bin/nix run "''${FLAKE}#''${runner}" "''${BUILD_FLAGS[@]}" -- "''${EXTRA_ARGS[@]}"
    }

    do_test() {
      echo -e "''${BLUE}Building and testing (profile: $PROFILE)...''${RESET}" >&2

      # Build toplevel to track generation
      local attr
      attr=$(resolve_toplevel_attr)
      local toplevel
      toplevel=$(${pkgs.nix}/bin/nix build "''${FLAKE}#''${attr}" \
        --no-link --print-out-paths "''${BUILD_FLAGS[@]}" 2>&1 | tail -1)

      if [ -d "$toplevel" ]; then
        update_generation "$toplevel"
      fi

      echo -e "''${BLUE}Running boot test...''${RESET}" >&2
      ${pkgs.nix}/bin/nix run "''${FLAKE}#boot-test" "''${BUILD_FLAGS[@]}" -- "''${EXTRA_ARGS[@]}"
    }

    do_diff() {
      local current
      current=$(current_generation_path)

      if [ -z "$current" ]; then
        echo -e "''${YELLOW}No current generation. Build first with: redox-rebuild build''${RESET}" >&2
        exit 1
      fi

      echo -e "''${BLUE}Building new configuration for diff (profile: $PROFILE)...''${RESET}" >&2
      local attr
      attr=$(resolve_toplevel_attr)
      local new_toplevel
      new_toplevel=$(${pkgs.nix}/bin/nix build "''${FLAKE}#''${attr}" \
        --no-link --print-out-paths "''${BUILD_FLAGS[@]}" 2>&1 | tail -1)

      if [ ! -d "$new_toplevel" ]; then
        echo -e "''${RED}Build failed.''${RESET}" >&2
        exit 1
      fi

      if [ "$current" = "$new_toplevel" ]; then
        echo -e "''${GREEN}No changes.''${RESET} Current system is up to date."
        exit 0
      fi

      local old_root new_root
      old_root=$(readlink -f "$current/root-tree")
      new_root=$(readlink -f "$new_toplevel/root-tree")

      echo ""
      echo -e "''${BOLD}=== Version Changes ===''${RESET}"
      ${pkgs.diffutils}/bin/diff --color=auto \
        <(${pkgs.python3}/bin/python3 -m json.tool "$current/version.json" 2>/dev/null) \
        <(${pkgs.python3}/bin/python3 -m json.tool "$new_toplevel/version.json" 2>/dev/null) \
        || true

      echo ""
      echo -e "''${BOLD}=== Component Changes ===''${RESET}"
      ${pkgs.diffutils}/bin/diff --color=auto \
        "$current/nix-support/build-info" \
        "$new_toplevel/nix-support/build-info" \
        || true

      echo ""
      echo -e "''${BOLD}=== Root Tree File Changes ===''${RESET}"
      ${pkgs.diffutils}/bin/diff --color=auto \
        <(cd "$old_root" && find . -type f | sort) \
        <(cd "$new_root" && find . -type f | sort) \
        || true

      echo ""
      echo -e "''${BOLD}=== Config File Changes ===''${RESET}"
      for f in etc/passwd etc/group etc/profile etc/hostname etc/init.toml startup.sh; do
        if [ -f "$old_root/$f" ] && [ -f "$new_root/$f" ]; then
          if ! ${pkgs.diffutils}/bin/diff -q "$old_root/$f" "$new_root/$f" >/dev/null 2>&1; then
            echo -e "''${YELLOW}--- $f''${RESET}"
            ${pkgs.diffutils}/bin/diff --color=auto "$old_root/$f" "$new_root/$f" || true
            echo ""
          fi
        elif [ -f "$new_root/$f" ] && [ ! -f "$old_root/$f" ]; then
          echo -e "''${GREEN}+++ $f (new)''${RESET}"
        elif [ -f "$old_root/$f" ] && [ ! -f "$new_root/$f" ]; then
          echo -e "''${RED}--- $f (removed)''${RESET}"
        fi
      done

      echo ""
      echo -e "''${BOLD}Old:''${RESET} $current"
      echo -e "''${BOLD}New:''${RESET} $new_toplevel"
    }

    do_check() {
      local attr
      attr=$(resolve_toplevel_attr)
      echo -e "''${BLUE}Checking system configuration (profile: $PROFILE)...''${RESET}" >&2

      # Building the toplevel triggers assertions (eval-time) and systemChecks (build-time)
      ${pkgs.nix}/bin/nix build "''${FLAKE}#''${attr}" \
        --no-link "''${BUILD_FLAGS[@]}"

      echo -e "''${GREEN}All assertions and system checks passed.''${RESET}"
    }

    # Collect generation links sorted by number
    sorted_gen_links() {
      local links=()
      for link in "$GEN_DIR"/system-*-link; do
        [ -L "$link" ] || continue
        links+=("$link")
      done
      if [ ''${#links[@]} -eq 0 ]; then
        return
      fi
      printf '%s\n' "''${links[@]}" | sort -t- -k2 -n
    }

    do_list_generations() {
      local gen_links
      gen_links=$(sorted_gen_links)

      if [ -z "$gen_links" ]; then
        if [ "$JSON" = "1" ]; then
          echo "[]"
        else
          echo "No generations. Build first with: redox-rebuild build"
        fi
        return 0
      fi

      local current
      current=$(current_generation_path)

      if [ "$JSON" = "1" ]; then
        echo "["
        local first=1
        while IFS= read -r link; do
          local gen_num target date_epoch date_str is_current version_json
          gen_num=$(basename "$link" | ${pkgs.gnused}/bin/sed 's/system-\([0-9]*\)-link/\1/')
          target=$(readlink -f "$link")
          date_epoch=$(stat -c '%Y' "$link" 2>/dev/null || echo "0")
          date_str=$(date -d "@$date_epoch" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo "unknown")
          is_current="false"
          [ "$target" = "$current" ] && is_current="true"
          version_json=$(cat "$target/version.json" 2>/dev/null || echo '{}')

          [ "$first" = "1" ] || printf ",\n"
          printf '  {"generation": %s, "date": "%s", "current": %s, "toplevel": "%s", "version": %s}' \
            "$gen_num" "$date_str" "$is_current" "$target" "$version_json"
          first=0
        done <<< "$gen_links"
        echo ""
        echo "]"
      else
        printf "''${BOLD}%-5s  %-20s  %-8s  %-8s  %-10s  %s''${RESET}\n" \
          "Gen" "Date" "Current" "Pkgs" "Hostname" "Toplevel"
        while IFS= read -r link; do
          local gen_num target date_epoch date_str mark pkg_count hostname
          gen_num=$(basename "$link" | ${pkgs.gnused}/bin/sed 's/system-\([0-9]*\)-link/\1/')
          target=$(readlink -f "$link")
          date_epoch=$(stat -c '%Y' "$link" 2>/dev/null || echo "0")
          date_str=$(date -d "@$date_epoch" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")
          mark=""
          [ "$target" = "$current" ] && mark="*"
          pkg_count=$(${pkgs.gnugrep}/bin/grep -o '"packageCount":[0-9]*' "$target/version.json" 2>/dev/null | cut -d: -f2 || echo "?")
          hostname=$(${pkgs.gnugrep}/bin/grep -o '"hostname":"[^"]*"' "$target/version.json" 2>/dev/null | cut -d'"' -f4 || echo "?")
          printf "%-5s  %-20s  %-8s  %-8s  %-10s  %s\n" \
            "$gen_num" "$date_str" "$mark" "$pkg_count" "$hostname" "$target"
        done <<< "$gen_links"
      fi
    }

    do_rollback() {
      if [ ! -d "$GEN_DIR" ]; then
        echo -e "''${RED}No generations found.''${RESET}" >&2
        exit 1
      fi

      local target_gen=""
      if [ ''${#EXTRA_ARGS[@]} -gt 0 ]; then
        target_gen="''${EXTRA_ARGS[0]}"
      fi

      if [ -n "$target_gen" ]; then
        # Rollback to specific generation
        local link="$GEN_DIR/system-''${target_gen}-link"
        if [ ! -L "$link" ]; then
          echo -e "''${RED}Generation $target_gen not found.''${RESET}" >&2
          echo "Available generations:" >&2
          sorted_gen_links | while IFS= read -r l; do
            basename "$l" | ${pkgs.gnused}/bin/sed 's/system-\([0-9]*\)-link/  \1/'
          done >&2
          exit 1
        fi
        local target
        target=$(readlink -f "$link")
        ln -sfn "$target" "$GEN_DIR/system"
        echo -e "''${GREEN}Switched to generation $target_gen.''${RESET}"
        echo "  $target"
      else
        # Rollback to previous generation
        local current
        current=$(current_generation_path)
        local prev_link=""
        local prev_gen=""
        while IFS= read -r link; do
          [ -n "$link" ] || continue
          local target
          target=$(readlink -f "$link")
          if [ "$target" = "$current" ]; then
            break
          fi
          prev_link="$link"
          prev_gen=$(basename "$link" | ${pkgs.gnused}/bin/sed 's/system-\([0-9]*\)-link/\1/')
        done <<< "$(sorted_gen_links)"

        if [ -z "$prev_link" ]; then
          echo -e "''${RED}No previous generation to roll back to.''${RESET}" >&2
          exit 1
        fi

        local target
        target=$(readlink -f "$prev_link")
        ln -sfn "$target" "$GEN_DIR/system"
        echo -e "''${GREEN}Rolled back to generation $prev_gen.''${RESET}"
        echo "  $target"
      fi
    }

    do_repl() {
      local flake_path
      flake_path=$(resolve_flake_path)
      local system
      system=$(${pkgs.nix}/bin/nix eval --impure --raw --expr 'builtins.currentSystem')

      echo -e "''${BLUE}Loading RedoxOS system configuration into repl...''${RESET}" >&2
      echo "Available:" >&2
      echo "  flake              — the full flake" >&2
      echo "  systems.default    — default system config" >&2
      echo "  systems.minimal    — minimal system config" >&2
      echo "  systems.graphical  — graphical system config" >&2
      echo "  systems.cloud      — cloud system config" >&2
      echo "" >&2

      ${pkgs.nix}/bin/nix repl --extra-experimental-features 'nix-command flakes' \
        --impure --expr "
          let
            flake = builtins.getFlake \"''${flake_path}\";
            lp = flake.legacyPackages.''${system};
          in {
            inherit flake;
            systems = lp.redoxConfigurations;
            mkSystem = lp.mkRedoxSystem;
            lib = flake.inputs.nixpkgs.lib;
          }
        "
    }

    do_edit() {
      local flake_path
      flake_path=$(resolve_flake_path)
      exec "''${EDITOR:-vi}" "''${flake_path}/flake.nix"
    }

    do_changelog() {
      local flake_path
      flake_path=$(resolve_flake_path)
      echo -e "''${BOLD}Recent module system changes:''${RESET}"
      echo ""
      ${pkgs.git}/bin/git -C "''${flake_path}" log \
        --oneline --color=always -20 \
        -- nix/redox-system/ nix/vendor/adios/ nix/vendor/korora/
    }

    do_version() {
      local current
      current=$(current_generation_path)

      if [ -z "$current" ]; then
        echo -e "''${YELLOW}No current generation. Build first with: redox-rebuild build''${RESET}" >&2
        # Still show the version from a quick eval
        echo -e "''${BLUE}Evaluating current configuration...''${RESET}" >&2
        local system
        system=$(${pkgs.nix}/bin/nix eval --impure --raw --expr 'builtins.currentSystem' 2>/dev/null)
        ${pkgs.nix}/bin/nix eval "''${FLAKE}#legacyPackages.''${system}.redoxConfigurations.''${PROFILE}.version" --json "''${BUILD_FLAGS[@]}" 2>/dev/null \
          | ${pkgs.python3}/bin/python3 -m json.tool 2>/dev/null \
          || echo "(evaluation failed — try 'redox-rebuild build' first)"
        exit 0
      fi

      if [ "$JSON" = "1" ]; then
        cat "$current/version.json"
      else
        echo -e "''${BOLD}Current system:''${RESET} $current"
        echo ""
        ${pkgs.python3}/bin/python3 -m json.tool "$current/version.json" 2>/dev/null \
          || cat "$current/version.json"
      fi
    }

    # === Dispatch ===
    case "$ACTION" in
      build)            do_build ;;
      run)              do_run ;;
      test)             do_test ;;
      diff)             do_diff ;;
      check)            do_check ;;
      list-generations) do_list_generations ;;
      rollback)         do_rollback ;;
      repl)             do_repl ;;
      edit)             do_edit ;;
      changelog)        do_changelog ;;
      version)          do_version ;;
      *)
        echo -e "''${RED}Unknown action: $ACTION''${RESET}" >&2
        exit 1
        ;;
    esac
''
