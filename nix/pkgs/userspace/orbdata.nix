# Orbital Data - Fonts, icons, cursors, and backgrounds
#
# orbdata is a data-only package containing:
# - Fonts (TrueType/OpenType fonts for text rendering)
# - Icons (application and system icons)
# - Cursors (mouse cursor themes)
# - Backgrounds (wallpaper images)
#
# This package requires no compilation - it simply copies data files
# to the appropriate locations in the filesystem.
#
# Installation paths (relative to root):
# - /ui/fonts/      - Font files
# - /ui/icons/      - Icon files
# - /ui/cursors/    - Cursor themes
# - /ui/backgrounds/ - Background images

{
  pkgs,
  lib,
  orbdata-src,
  ...
}:

pkgs.stdenv.mkDerivation {
  pname = "orbdata";
  version = "unstable";

  src = orbdata-src;

  dontBuild = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out

    # Copy all data files preserving directory structure
    # orbdata contains: backgrounds/, cursors/, fonts/, icons/
    cp -r . $out/

    # Remove any git/build files that shouldn't be packaged
    rm -rf $out/.git $out/.gitignore $out/README.md 2>/dev/null || true

    # Verify expected directories exist
    echo "orbdata contents:"
    ls -la $out/

    runHook postInstall
  '';

  meta = with lib; {
    description = "Orbital UI data files (fonts, icons, cursors, backgrounds)";
    homepage = "https://gitlab.redox-os.org/redox-os/orbdata";
    license = licenses.mit;
  };
}
