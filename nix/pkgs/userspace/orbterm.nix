# Orbterm - Terminal Emulator for Orbital
#
# STATUS: BLOCKED - Vendor hash computed, build needs orbfont/orbimage deps
#
# Orbterm is a graphical terminal emulator for Redox OS that runs within
# the Orbital windowing system. It provides:
# - VT100/ANSI terminal emulation
# - TrueType font rendering
# - Copy/paste support
# - Scrollback buffer
# - UI configuration files
#
# Dependencies:
# - orbital: Display server (runtime dependency) - BLOCKED
# - orbclient: Client library for connecting to Orbital
# - orbfont: Font rendering
# - orbimage: Image loading
# - libredox: Redox OS system library
#
# The vendor hash computed for orbterm's deps is:
#   sha256-/ZLt7HMD3wXQsXSiaNEFwURJYBYOwj9TNcR8CUUjB5k=
#
# TODO: To complete this package:
# 1. Complete orbital package first (orbterm depends on it at runtime)
# 2. Add orbfont-src and orbimage-src flake inputs
# 3. Patch orbfont/orbimage path dependencies
# 4. Build orbterm binary
#
# For now, use the graphical disk image without orbterm binary.

{
  pkgs,
  lib,
  ...
}:

# Return a placeholder derivation that documents the blocked status
pkgs.runCommand "orbterm-blocked" { } ''
    mkdir -p $out
    cat > $out/README << 'EOF'
  Orbterm package is currently blocked (depends on orbital which is blocked).

  Orbterm is a graphical terminal emulator for Redox OS.

  The vendor hash has been computed:
    sha256-/ZLt7HMD3wXQsXSiaNEFwURJYBYOwj9TNcR8CUUjB5k=

  To complete this package:
  1. First resolve orbital package dependencies
  2. Then build orbterm which depends on orbital at runtime

  For now, the graphical disk image includes:
  - Graphics drivers (vesad, inputd, bgad, virtio-gpud)
  - orbdata (fonts, icons, cursors)

  But no graphical applications until orbital is resolved.
  EOF
''
