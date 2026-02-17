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
# Upstream repo layout (as of commit 91a1f08):
#   ui/           - cursors, window decorations, config
#   usr/share/fonts/ - font files (Mono/Fira, Sans/Fira)
#   usr/share/icons/ - application and system icons
#
# Orbital's orbfont crate looks for fonts at /ui/fonts/ on Redox,
# so we create /ui/fonts/ and /ui/icons/ from /usr/share/.

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
    cp -r . $out/

    # Remove any git/build files that shouldn't be packaged
    rm -rf $out/.git $out/.gitignore $out/.gitmodules $out/README.md 2>/dev/null || true

    # Orbital's orbfont crate hardcodes /ui/fonts/ for font lookup on Redox.
    # Upstream moved fonts from ui/fonts/ to usr/share/fonts/.
    # Copy fonts/icons into ui/ so orbfont can find them.
    if [ -d "$out/usr/share/fonts" ] && [ ! -d "$out/ui/fonts" ]; then
      echo "Copying fonts from usr/share/fonts/ to ui/fonts/ for orbfont compatibility"
      cp -r $out/usr/share/fonts $out/ui/fonts
    fi
    if [ -d "$out/usr/share/icons" ] && [ ! -d "$out/ui/icons" ]; then
      echo "Copying icons from usr/share/icons/ to ui/icons/"
      cp -r $out/usr/share/icons $out/ui/icons
    fi

    echo "orbdata contents:"
    ls -la $out/ui/
    echo "Fonts:"
    find $out/ui/fonts -name "*.ttf" 2>/dev/null || echo "No fonts found!"

    runHook postInstall
  '';

  meta = with lib; {
    description = "Orbital UI data files (fonts, icons, cursors, backgrounds)";
    homepage = "https://gitlab.redox-os.org/redox-os/orbdata";
    license = licenses.mit;
  };
}
