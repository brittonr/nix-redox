# Complete browser-image inputs, without conflating transfer and logical sizes.
{
  pkgs,
  system,
  machine,
}:
pkgs.runCommand "redox-browser-image" { } ''
  mkdir -p $out/boot $out/fixtures
  ln -s ${system.diskImage}/redox.img $out/redox.img
  cp -r ${system.diskImage}/boot/. $out/boot/
  cp ${machine} $out/machine.json
  cp ${../redox-system/fixtures/browser-demo/catalog.json} $out/fixtures/catalog.json
''
