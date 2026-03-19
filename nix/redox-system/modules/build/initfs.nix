# Initial filesystem (initfs) derivation
# Creates the compressed filesystem image used during early boot.
# Contains essential daemons, drivers, and numbered init scripts.

{ hostPkgs, pkgs, lib, cfg, initScriptFiles, pcidToml }:

hostPkgs.stdenv.mkDerivation {
  pname = "redox-initfs";
  version = "unstable";
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.initfsTools ];
  buildPhase = ''
    runHook preBuild
    mkdir -p initfs/{bin,lib/drivers,etc/{init.d,pcid.d,ion},usr/bin,usr/lib/drivers}

    ${lib.concatStringsSep "\n" (
      builtins.map (d: ''
        [ -f ${pkgs.base}/bin/${d} ] && cp ${pkgs.base}/bin/${d} initfs/bin/
      '') cfg.allDaemons
    )}

    cp ${pkgs.base}/bin/zerod initfs/bin/nulld
    cp ${pkgs.redoxfsTarget}/bin/redoxfs initfs/bin/
    cp ${pkgs.ion}/bin/ion initfs/bin/ion
    cp ${pkgs.ion}/bin/ion initfs/usr/bin/ion
    cp ${pkgs.ion}/bin/ion initfs/bin/sh
    cp ${pkgs.ion}/bin/ion initfs/usr/bin/sh

    ${lib.optionalString (pkgs ? netutils) ''
      [ -f ${pkgs.netutils}/bin/ifconfig ] && cp ${pkgs.netutils}/bin/ifconfig initfs/bin/
      [ -f ${pkgs.netutils}/bin/ping ] && cp ${pkgs.netutils}/bin/ping initfs/bin/
    ''}

    ${lib.optionalString (pkgs ? userutils) ''
      for bin in getty login; do
        [ -f ${pkgs.userutils}/bin/$bin ] && cp ${pkgs.userutils}/bin/$bin initfs/bin/
      done
    ''}

    ${lib.concatStringsSep "\n" (
      builtins.map (d: ''
        [ -f ${pkgs.base}/bin/${d} ] && cp -f ${pkgs.base}/bin/${d} initfs/lib/drivers/
      '') cfg.allDrivers
    )}

    ${lib.optionalString cfg.usbEnabled ''
      for drv in xhcid usbhubd usbhidd; do
        [ -f ${pkgs.base}/bin/$drv ] && cp -f ${pkgs.base}/bin/$drv initfs/lib/drivers/
      done
      for bin in usbhubd usbhidd; do
        [ -f ${pkgs.base}/bin/$bin ] && cp -f ${pkgs.base}/bin/$bin initfs/bin/
        [ -f ${pkgs.base}/bin/$bin ] && cp -f ${pkgs.base}/bin/$bin initfs/usr/lib/drivers/
      done
    ''}

    # Write pcid config to new location (etc/pcid.d/ instead of etc/pcid/)
    cat > initfs/etc/pcid.d/initfs.toml << 'PCID_EOF'
    ${pcidToml}
PCID_EOF

    # Write numbered init.d scripts (new init system format)
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: content: ''
        cat > initfs/etc/init.d/${name} << 'INIT_SCRIPT_EOF'
        ${content}
INIT_SCRIPT_EOF
      '') (lib.filterAttrs (_: content: content != "") initScriptFiles)
    )}

    # Ion shell configuration
    echo 'let PROMPT = "${cfg.initfsPrompt}"' > initfs/etc/ion/initrc

    redox-initfs-ar initfs ${pkgs.bootstrap}/bin/bootstrap -o initfs.img --max-size ${
      toString (cfg.initfsSizeMB * 1024 * 1024)
    }
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p $out/boot
    cp initfs.img $out/boot/initfs
    runHook postInstall
  '';
}