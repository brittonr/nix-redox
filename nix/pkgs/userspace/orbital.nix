# Orbital - Display Server and Window Manager for Redox OS
#
# STATUS: BLOCKED - Complex nested dependencies not yet resolved
#
# Orbital is the windowing system and compositor for Redox OS. It provides:
# - Display management (resolution, multiple monitors)
# - Window management (tiling, floating windows)
# - Input event handling (keyboard, mouse)
# - Compositing and rendering
#
# Dependencies that need resolution:
# - graphics-ipc: From base package, has redox-ioctl git dependency
# - inputd: From base package, depends on daemon and redox-scheme 0.8.3
# - daemon: From base package, needed by inputd
# - drm/drm-sys: Transitive dependencies of graphics-ipc
# - redox-scheme: Version conflict (0.8.3 required by inputd, 0.8.2 in vendor)
#
# The vendor hash computed for orbital's own deps is:
#   sha256-Bz+sB+G+DO9TavMpI7zS5O4a6Bktg0mNXQRRQnyJfTA=
#
# TODO: To complete this package:
# 1. Pin redox-scheme 0.8.3 in the dependency tree
# 2. Create a unified workspace including all path deps from base
# 3. Vendor all transitive dependencies together
# 4. Or: wait for upstream to publish crates to crates.io
#
# For now, use the graphical disk image without orbital binary.
# The initfs still includes graphics drivers (vesad, inputd, bgad, virtio-gpud).

{
  pkgs,
  lib,
  ...
}:

# Return a placeholder derivation that documents the blocked status
pkgs.runCommand "orbital-blocked" { } ''
    mkdir -p $out
    cat > $out/README << 'EOF'
  Orbital package is currently blocked due to complex nested dependencies.

  The following issues need resolution:
  - redox-scheme version conflict (0.8.3 required, 0.8.2 available)
  - Nested path dependencies from base package (graphics-ipc, inputd, daemon)
  - Git dependencies that need path conversion (redox-ioctl from relibc)

  Graphics drivers ARE included in the graphical initfs:
  - vesad (VESA display driver)
  - inputd (input device daemon)
  - bgad (Bochs Graphics Adapter)
  - virtio-gpud (VirtIO GPU driver)

  To test graphics without Orbital:
  1. Build: nix build .#diskImageGraphical
  2. Run: nix run .#runQemuGraphical
  3. Graphics drivers will initialize but no desktop will appear

  The orbdata package (fonts, icons, cursors) IS available and included.
  EOF
''
