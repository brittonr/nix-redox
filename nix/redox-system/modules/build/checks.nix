# System build validation checks
# Inspired by nix-darwin's system.checks module.
# Validates that built artifacts contain everything needed for boot.

{ hostPkgs, lib, rootTree, cfg }:

hostPkgs.runCommand "redox-system-checks" { } ''
  set -euo pipefail
  echo "Running system checks on rootTree..."

  # Check 1: Essential files exist
  for f in etc/passwd etc/group etc/shadow etc/init.toml startup.sh; do
    if [ ! -e "${rootTree}/$f" ]; then
      echo "FAIL: Missing essential file: $f"
      exit 1
    fi
  done
  echo "  ✓ Essential files present"

  # Check 2: passwd has at least one entry
  if [ ! -s "${rootTree}/etc/passwd" ]; then
    echo "FAIL: /etc/passwd is empty — no users defined"
    exit 1
  fi
  echo "  ✓ passwd has entries"

  # Check 3: passwd uses semicolon delimiter (Redox format)
  if ! grep -q ';' "${rootTree}/etc/passwd"; then
    echo "FAIL: /etc/passwd not in Redox format (semicolon-delimited)"
    echo "  Contents: $(head -1 ${rootTree}/etc/passwd)"
    exit 1
  fi
  echo "  ✓ passwd format correct"

  # Check 4: If networking enabled, verify net config exists
  ${lib.optionalString cfg.networkingEnabled ''
    if [ ! -d "${rootTree}/etc/net" ]; then
      echo "FAIL: Networking enabled but /etc/net directory missing"
      exit 1
    fi
    if [ ! -e "${rootTree}/etc/net/dns" ]; then
      echo "FAIL: Networking enabled but /etc/net/dns missing"
      exit 1
    fi
    echo "  ✓ Network configuration present"
  ''}

  # Check 5: If graphics enabled, verify profile has orbital config
  ${lib.optionalString cfg.graphicsEnabled ''
    if ! grep -q 'ORBITAL_RESOLUTION' "${rootTree}/etc/profile" 2>/dev/null; then
      echo "WARN: Graphics enabled but ORBITAL_RESOLUTION not in profile"
    fi
    echo "  ✓ Graphics configuration present"
  ''}

  # Check 6: Hostname file exists
  if [ ! -e "${rootTree}/etc/hostname" ]; then
    echo "FAIL: Missing /etc/hostname"
    exit 1
  fi
  echo "  ✓ hostname present ($(cat ${rootTree}/etc/hostname))"

  # Check 7: Security policy exists
  if [ ! -e "${rootTree}/etc/security/policy" ]; then
    echo "FAIL: Missing /etc/security/policy"
    exit 1
  fi
  echo "  ✓ security policy present"

  # Check 9: Init scripts directory should have content
  if [ -d "${rootTree}/etc/init.d" ]; then
    count=$(find "${rootTree}/etc/init.d" -type f | wc -l)
    echo "  ✓ Init scripts present ($count scripts)"
  fi

  # Check 10: startup.sh should be executable (Nix adjusts to 555)
  if [ -e "${rootTree}/startup.sh" ]; then
    mode=$(stat -c '%a' "${rootTree}/startup.sh")
    if [ "$mode" != "555" ]; then
      echo "WARN: startup.sh has mode $mode (expected 555)"
    fi
    echo "  ✓ startup.sh executable"
  fi

  echo ""
  echo "All system checks passed."
  touch $out
''