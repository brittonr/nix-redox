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

    mkdir -p $out/etc/ssl/certs

    # Generate concatenated bundle file first (before copying read-only PEM files)
    # This is what rustls-native-certs, curl, and most TLS clients look for.
    cat ${ca-certificates-src}/certs/*.pem > $out/etc/ssl/certs/ca-certificates.crt

    # Copy individual certs and hash symlinks
    cp -rv ${ca-certificates-src}/certs/. $out/etc/ssl/certs/

    # Compatibility symlink (legacy location)
    ln -s etc/ssl $out/ssl

    # Verify
    test -d $out/etc/ssl/certs || { echo "ERROR: no certs directory"; exit 1; }
    certCount=$(find $out/etc/ssl/certs -name '*.pem' | wc -l)
    echo "Installed $certCount certificates"
    test -f $out/etc/ssl/certs/ca-certificates.crt || { echo "ERROR: no bundle file"; exit 1; }
    bundleSize=$(wc -c < $out/etc/ssl/certs/ca-certificates.crt)
    echo "Bundle: $bundleSize bytes"

    runHook postInstall
  '';

  meta = with lib; {
    description = "Mozilla CA certificate bundle for TLS verification";
    homepage = "https://gitlab.redox-os.org/redox-os/ca-certificates";
    license = licenses.mpl20;
  };
}
