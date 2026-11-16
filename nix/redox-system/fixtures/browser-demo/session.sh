#!/nix/system/profile/bin/bash
set -u
source /etc/browser-demo/common.sh
# Token-framed execution avoids confusing echoed input or a prompt with command
# completion. The caller supplies a fresh alphanumeric/hyphen/underscore token.
browser_command() {
    local token status
    token=${1:-}
    case "$token" in ''|*[!a-zA-Z0-9_-]*) return 2;; esac
    shift
    ( "$@" )
    status=$?
    printf 'REDOX_BROWSER_DEMO_COMMAND:%s:%s\n' "$token" "$status"
    return "$status"
}
if ! /nix/system/profile/bin/bash /etc/browser-demo/ready.sh; then
    printf '%s\n' 'REDOX_BROWSER_DEMO_NOT_READY:v1'
    exit 1
fi
# A blocking line-oriented shell works on Redox's serial debug: scheme, where
# terminal raw-mode operations used by interactive shells are unavailable.
while true; do
    printf 'browser-demo$ '
    IFS= read -r command || exit 0
    test -z "$command" || eval "$command"
done
