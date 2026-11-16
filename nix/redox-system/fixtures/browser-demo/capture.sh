#!/nix/system/profile/bin/bash
set -euo pipefail
token=${1:-}
case "$token" in
    ''|*[!a-zA-Z0-9_-]*)
        printf '%s\n' 'usage: capture.sh alphanumeric-token' >&2
        exit 2
        ;;
esac
# Flush through real mounted guest file descriptors, including all writable
# fixture/store/configuration/result locations. The filesystem's directory
# descriptors do not support fsync; the helper walks real files, not symlinks.
# Any flush error aborts before CAPTURE_READY, so the host cannot save a falsely
# durable capture. No store/profile cleanup or configuration mutation occurs.
# The ESP is not mounted at /boot; its bytes are captured with the inactive
# whole-disk image after QEMU drains and flushes the block graph.
/nix/system/profile/bin/browser-demo-flush /etc /nix /var /tmp /root /home
printf 'REDOX_BROWSER_CAPTURE_READY:v1:%s\n' "$token"
# Save the emulator while this reader is blocked. The restore driver sends the
# same line to the saved reader; unrelated input cannot satisfy the handshake.
while IFS= read -r line; do
    if test "$line" = "REDOX_BROWSER_RESUME:v1:$token"; then
        printf 'REDOX_BROWSER_RESUMED:v1:%s\n' "$token"
        exit 0
    fi
done
printf '%s\n' 'capture.sh: serial input ended before matching resume token' >&2
exit 1
