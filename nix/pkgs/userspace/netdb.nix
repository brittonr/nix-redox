# netdb - Network database files for Redox OS
#
# Contains /etc/hosts, /etc/services, /etc/protocols, and other
# network-related database files used by the resolver.
#
# Source: gitlab.redox-os.org/redox-os/netdb
# No compilation needed — just file copies.

{
  pkgs,
  lib,
  netdb-src,
  ...
}:

pkgs.stdenv.mkDerivation {
  pname = "netdb";
  version = "unstable";

  dontUnpack = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    # Copy all files from the source (the repo IS the database)
    mkdir -p $out
    cp -rv ${netdb-src}/* $out/

    # Remove git metadata if present
    rm -rf $out/.git $out/.gitignore 2>/dev/null || true

    # Verify key files exist
    for f in etc/hosts etc/services etc/protocols; do
      if [ -e "$out/$f" ]; then
        echo "Found: $f"
      fi
    done

    runHook postInstall
  '';

  meta = with lib; {
    description = "Network database files (hosts, services, protocols)";
    homepage = "https://gitlab.redox-os.org/redox-os/netdb";
    license = licenses.mit;
  };
}
