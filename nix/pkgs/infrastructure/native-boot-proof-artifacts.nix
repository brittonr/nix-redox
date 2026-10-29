# Test-only seed artifacts. Keep the normal monolithic package layouts and
# dependencies, but compile the same runtime instrumentation as the native bundle.
# IDs are each executing derivation's output root, not an image/test-runner label.
{ pkgs, kernel, bootloader }:

let
  instrument = component: package: package.overrideAttrs (old: {
    pname = "${old.pname}-native-boot-proof";
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.python3 ];
    postConfigure = (old.postConfigure or "") + ''
      python3 ${./patch-native-boot-proof.py} ${component} .
    '';
    preBuild = (old.preBuild or "") + ''
      export REDOX_BOOT_PROOF_ID="$out"
    '';
    postInstall = (old.postInstall or "") + ''
      printf '%s\n' "$out" > "$out/boot-proof-id"
    '';
  });
in
{
  kernel = instrument "kernel" kernel;
  bootloader = instrument "bootloader" bootloader;
}
