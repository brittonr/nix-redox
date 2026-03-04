# Compiled CC wrapper for Redox self-hosting
#
# Wraps ld.lld with CRT files and sysroot libraries.
# Written as a compiled binary (not an Ion script) because Ion's argument
# parser treats -o as its own keybinding option, breaking:
#   cc foo.o -o output  →  ion sees -o and expects "vi"/"emacs"
#
# For compile-only: would need clang (which is too large for Redox's ELF loader).
# For linking: invokes ld.lld directly with CRT objects and libc.

{
  pkgs,
  lib,
  mkUserspace,
}:

mkUserspace.mkBinary {
  pname = "cc-wrapper-redox";
  version = "0.1.0";
  binaryName = "cc-wrapper";

  src = pkgs.writeTextDir "src/main.rs" ''
    use std::os::unix::process::CommandExt;
    use std::process::Command;

    fn main() {
        let sysroot = "/usr/lib/redox-sysroot";
        let lld = "/nix/system/profile/bin/ld.lld";

        let args: Vec<String> = std::env::args().skip(1).collect();

        let mut cmd = Command::new(lld);
        cmd.arg(format!("{}/lib/crt0.o", sysroot));
        cmd.arg(format!("{}/lib/crti.o", sysroot));
        for arg in &args {
            cmd.arg(arg);
        }
        cmd.arg("-L");
        cmd.arg(format!("{}/lib", sysroot));
        cmd.arg("-l:libc.a");
        cmd.arg("-l:libpthread.a");
        cmd.arg(format!("{}/lib/crtn.o", sysroot));

        let err = cmd.exec();
        eprintln!("cc-wrapper: failed to exec {}: {}", lld, err);
        std::process::exit(1);
    }
  '';

  # Minimal Cargo.toml
  cargoToml = ''
    [package]
    name = "cc-wrapper"
    version = "0.1.0"
    edition = "2021"
  '';

  needsBuildStd = true;
}
