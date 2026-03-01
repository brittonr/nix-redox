# terminfo - Terminal capability database for Redox OS
#
# Contains compiled terminfo entries for common terminal types:
# ansi, dumb, linux, screen, tmux, vt100, xterm (and variants).
#
# Source: github.com/sajattack/terminfo
# No compilation needed — just file copies.

{
  pkgs,
  lib,
  terminfo-src,
  ...
}:

pkgs.stdenv.mkDerivation {
  pname = "terminfo";
  version = "unstable";

  dontUnpack = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    # Copy common terminal entries (matching upstream recipe)
    mkdir -p $out/share/terminfo/{a,d,l,s,t,v,x}
    cp -r ${terminfo-src}/tabset $out/share/

    # ansi terminals
    for f in ${terminfo-src}/terminfo/a/ansi*; do
      [ -e "$f" ] && cp "$f" $out/share/terminfo/a/
    done

    # dumb terminal
    for f in ${terminfo-src}/terminfo/d/dumb*; do
      [ -e "$f" ] && cp "$f" $out/share/terminfo/d/
    done

    # linux console
    for f in ${terminfo-src}/terminfo/l/linux*; do
      [ -e "$f" ] && cp "$f" $out/share/terminfo/l/
    done

    # screen
    for f in ${terminfo-src}/terminfo/s/screen*; do
      [ -e "$f" ] && cp "$f" $out/share/terminfo/s/
    done

    # tmux
    for f in ${terminfo-src}/terminfo/t/tmux*; do
      [ -e "$f" ] && cp "$f" $out/share/terminfo/t/
    done

    # vt100
    for f in ${terminfo-src}/terminfo/v/vt100*; do
      [ -e "$f" ] && cp "$f" $out/share/terminfo/v/
    done

    # xterm
    for f in ${terminfo-src}/terminfo/x/xterm*; do
      [ -e "$f" ] && cp "$f" $out/share/terminfo/x/
    done

    # Verify
    entryCount=$(find $out/share/terminfo -type f | wc -l)
    echo "Installed $entryCount terminfo entries"

    runHook postInstall
  '';

  meta = with lib; {
    description = "Terminal capability database for Redox OS";
    homepage = "https://github.com/sajattack/terminfo";
    license = licenses.free;
  };
}
