#!/nix/system/profile/bin/bash
set -eu
source /etc/browser-demo/common.sh
# This script is reached through the actual Bash executable on the serial
# startup path. The initial-state evaluation is a real Snix process, which is
# stronger than an emulator-start event.
test -x /bin/base64
test "$((6 * 7))" = 42
initial_state
if test "${1:-}" != --check-only; then
  printf '%s\n' 'REDOX_BROWSER_DEMO_READY:v1:shell=1:snix=1:initial=1'
fi
