{
  pkgs,
  lib,
  engine,
  vendor,
  image,
  machine,
  firmware,
  revision,
  evaluator ? null,
  cache ? null,
  snapshot ? null,
  graphical ? null,
}:
let
  firmwareFile = if lib.isDerivation firmware then "${firmware}/OVMF.fd" else toString firmware;
  optional =
    flag: value: lib.optionalString (value != null) " --${flag} ${lib.escapeShellArg (toString value)}";
  site =
    pkgs.runCommand "redox-browser-site-${revision}"
      {
        nativeBuildInputs = [ pkgs.python3 ];
        passthru = {
          serverScript = ./serve.py;
          smokeScript = ./smoke.py;
          testsScript = ./test_delivery.py;
          sourceRevision = revision;
        };
      }
      ''
        python3 ${./manifest.py} \
          --out "$out" --site ${../../site} \
          --engine ${engine} --vendor ${vendor} --image ${image} \
          --machine ${machine} --firmware ${firmwareFile} \
          --revision ${lib.escapeShellArg revision} \
          ${lib.optionalString (lib.isDerivation firmware) "--firmware-notices ${firmware}"} \
          --disk-chunker ${./chunk-disk.py} \
          ${optional "cache" cache} ${optional "evaluator" evaluator} ${optional "snapshot" snapshot}
        ${lib.optionalString (graphical != null) ''
          # Graphical has its own complete release and may not silently replace headless.
          mkdir -p "$out/graphical"
          cp -a ${graphical}/. "$out/graphical/"
        ''}
      '';
in
site
