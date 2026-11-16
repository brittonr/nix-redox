{ pkgs }:
let
  xtermPty = pkgs.fetchurl {
    url = "https://registry.npmjs.org/xterm-pty/-/xterm-pty-0.10.1.tgz";
    hash = "sha512-fF4x2iTTE2PmFRaZfQbO8iZB59Krf3q0ORAyYgesGFRGjUDJX36MpsjRVdmdIdA+HEzBcqMAcxzvaW7/rI088w==";
  };
  xterm = pkgs.fetchurl {
    url = "https://registry.npmjs.org/@xterm/xterm/-/xterm-5.5.0.tgz";
    hash = "sha512-hqJHYaQb5OptNunnyAnkHyM8aCjZ1MEIDTQu1iIbbTD/xops91NB5yq1ZK/dC2JDbVWtF23zUtl9JE2NqwT87A==";
  };
in
pkgs.runCommand "redox-browser-terminal-vendor" { } ''
  mkdir -p $out/licenses pty terminal
  mkdir -p $out/source
  cp ${xtermPty} $out/source/xterm-pty-0.10.1.tgz
  cp ${xterm} $out/source/xterm-5.5.0.tgz
  tar -xzf ${xtermPty} -C pty --strip-components=1
  tar -xzf ${xterm} -C terminal --strip-components=1
  cp pty/index.js $out/xterm-pty.js
  cp pty/LICENSE.txt $out/licenses/xterm-pty-MIT.txt
  cp terminal/lib/xterm.js terminal/css/xterm.css $out/
  cp terminal/LICENSE $out/licenses/xterm-MIT.txt
  cp pty/package.json $out/licenses/xterm-pty-package.json
  cp terminal/package.json $out/licenses/xterm-package.json
''
