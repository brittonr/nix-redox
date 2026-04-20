# bottom - Graphical system/process monitor for Redox OS
#
# A cross-platform graphical process/system monitor with a customizable
# interface and a multitude of features. Uses upstream bottom plus a
# narrow Redox-local patch set.
#
# Source: github.com/ClementTsang/bottom (upstream release 0.11.2)
# Binary: btm

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  bottom-src,
  ...
}:

let
  mkUserspace = import ./mk-userspace.nix {
    inherit
      pkgs
      lib
      rustToolchain
      sysrootVendor
      redoxTarget
      relibc
      stubLibs
      vendor
      ;
  };

  patchedSrc = pkgs.runCommand "bottom-src-patched" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    cp -r ${bottom-src} $out
    chmod -R u+w $out

    python3 - <<'PY' "$out/Cargo.toml"
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace('deploy = ["battery", "gpu", "zfs"]', 'deploy = ["gpu", "zfs"]', 1)
text = text.replace('ctrlc = { version = "3.5.0", features = ["termination"] }\n', "", 1)
text = text.replace(
    'unicode-width = "0.2.0"\n',
    'unicode-width = "0.2.0"\n\n[target.\'cfg(not(target_os = "redox"))\'.dependencies]\nctrlc = { version = "3.5.0", features = ["termination"] }\n',
    1,
)
path.write_text(text)
PY

    python3 - <<'PY' "$out/src/lib.rs"
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = """    // Set termination hook
    ctrlc::set_handler(move || {
"""
new = """    // Set termination hook
    #[cfg(not(target_os = \"redox\"))]
    ctrlc::set_handler(move || {
"""
if old not in text:
    raise SystemExit("bottom: expected lib.rs ctrlc snippet not found")
path.write_text(text.replace(old, new, 1))
PY

    substituteInPlace $out/src/collection/processes.rs \
      --replace-quiet 'target_os = "ios"))] {' 'target_os = "ios", target_os = "redox"))] {'

    substituteInPlace $out/src/collection/temperature.rs \
      --replace-quiet 'target_os = "ios"))] {' 'target_os = "ios", target_os = "redox"))] {'

    python3 - <<'PY' "$out/src/utils/cancellation_token.rs"
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = """        let (result, _) = self
            .cvar
            .wait_timeout(guard, duration)
            .expect(\"cancellation token lock should not be poisoned\");

        *result
"""
new = """        if cfg!(target_os = \"redox\") {
            let value = *guard;
            drop(guard);

            // Redox OS Condvar::wait_timeout hangs.
            std::thread::sleep(duration);
            return value;
        }

        let (result, _) = self
            .cvar
            .wait_timeout(guard, duration)
            .expect(\"cancellation token condvar should not be poisoned\");

        *result
"""
if old not in text:
    raise SystemExit("bottom: expected cancellation_token snippet not found")
path.write_text(text.replace(old, new, 1))
PY
  '';
in
mkUserspace.mkBinary {
  pname = "bottom";
  version = "unstable";
  src = patchedSrc;
  binaryName = "btm";

  vendorHash = "sha256-IG+6UUQhFanWjNprjwlPsFHfzxU+TGeNR82xiy+4bWg=";

  meta = with lib; {
    description = "Graphical process/system monitor";
    homepage = "https://github.com/ClementTsang/bottom";
    license = licenses.mit;
    mainProgram = "btm";
  };
}
