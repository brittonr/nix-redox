# ca-certificates - TLS root certificate bundle for Redox OS
#
# Contains Mozilla's CA certificate bundle for TLS verification.
# Installed to /etc/ssl/certs/ with a compatibility symlink at /ssl.
#
# Source: gitlab.redox-os.org/redox-os/ca-certificates
# No compilation needed — just file copies.

{
  pkgs,
  lib,
  ca-certificates-src,
  ...
}:

pkgs.stdenv.mkDerivation {
  pname = "ca-certificates";
  version = "unstable";

  dontUnpack = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/etc/ssl
    cp -rv ${ca-certificates-src}/certs $out/etc/ssl/certs

    # Compatibility symlink (legacy location)
    ln -s etc/ssl $out/ssl

    # Verify
    test -d $out/etc/ssl/certs || { echo "ERROR: no certs directory"; exit 1; }
    certCount=$(find $out/etc/ssl/certs -name '*.pem' -o -name '*.crt' | wc -l)
    echo "Installed $certCount certificates"

    runHook postInstall
  '';

  meta = with lib; {
    description = "Mozilla CA certificate bundle for TLS verification";
    homepage = "https://gitlab.redox-os.org/redox-os/ca-certificates";
    license = licenses.mpl20;
  };
}
