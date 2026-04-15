# lld-wrapper: Stack-growing launcher for ld.lld on Redox
#
# The Redox kernel gives the main thread ~8KB of stack, which isn't enough
# for lld's recursive symbol resolution and section layout. With JOBS>=2,
# concurrent linker invocations overflow and crash with:
#   fatal runtime error: failed to initiate panic, error 0, aborting
#
# Fix: spawn a thread with 16MB stack and exec() lld from it.
# Same pattern as patch-rustc-main-stack.patch for rustc.
#
# Cross-compiled for Redox using rustc directly (no cargo needed for a
# single-file binary with no dependencies beyond std).

{
  pkgs,
  lib,
  rustToolchain,
  redoxTarget,
  relibc,
  stubLibs,
}:

let
  relibcDir = "${relibc}/${redoxTarget}";
  clangBin = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang";

  src = pkgs.writeText "lld-wrapper-main.rs" ''
    use std::env;
    use std::fs;
    use std::os::unix::process::CommandExt;
    use std::process::Command;
    use std::thread;

    fn decode_utf16_argfile(path: &str, bytes: &[u8]) -> Result<Vec<String>, String> {
        let mut chunks = bytes.chunks_exact(2);
        if !chunks.remainder().is_empty() {
            return Err(format!("{} has odd byte length {}", path, bytes.len()));
        }

        let mut words: Vec<u16> = chunks
            .by_ref()
            .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]))
            .collect();

        if matches!(words.first(), Some(0xFEFF)) {
            words.remove(0);
        }

        let decoded = std::char::decode_utf16(words)
            .collect::<Result<String, _>>()
            .map_err(|err| format!("{} is not valid UTF-16LE: {}", path, err))?;

        let mut expanded = Vec::new();
        for line in decoded.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }

            let arg = if trimmed.starts_with('"') && trimmed.ends_with('"') && trimmed.len() >= 2 {
                trimmed[1..trimmed.len() - 1].to_string()
            } else {
                trimmed.to_string()
            };
            expanded.push(arg);
        }

        Ok(expanded)
    }

    fn expand_response_files(args: Vec<String>) -> Result<Vec<String>, String> {
        let mut expanded = Vec::new();

        for arg in args {
            if let Some(path) = arg.strip_prefix('@') {
                let bytes = fs::read(path)
                    .map_err(|err| format!("failed to read argfile {}: {}", path, err))?;

                if bytes.contains(&0) {
                    expanded.extend(decode_utf16_argfile(path, &bytes)?);
                } else {
                    expanded.push(arg);
                }
            } else {
                expanded.push(arg);
            }
        }

        Ok(expanded)
    }

    fn main() {
        let args = match expand_response_files(env::args().skip(1).collect()) {
            Ok(args) => args,
            Err(err) => {
                eprintln!("lld-wrapper: {}", err);
                std::process::exit(1);
            }
        };
        let stack_size: usize = 64 * 1024 * 1024; // 64 MB for deep COFF/UEFI links

        match thread::Builder::new()
            .name("lld-main".into())
            .stack_size(stack_size)
            .spawn(move || {
                let lld = env::var("PI_LLD_REAL")
                    .unwrap_or_else(|_| "/nix/system/profile/bin/ld.lld".to_string());
                let mut cmd = Command::new(&lld);
                cmd.env("LD_LIBRARY_PATH", "/nix/system/profile/lib:/usr/lib/rustc:/lib");
                for arg in &args {
                    cmd.arg(arg);
                }
                let err = cmd.exec();
                eprintln!("lld-wrapper: failed to exec {}: {}", lld, err);
                std::process::exit(1);
            })
        {
            Ok(handle) => {
                let _ = handle.join();
                // exec() replaces the process, so we only reach here on failure
                std::process::exit(0);
            }
            Err(e) => {
                eprintln!("lld-wrapper: failed to create thread: {}", e);
                std::process::exit(1);
            }
        }
    }
  '';
in
pkgs.runCommand "lld-wrapper"
  {
    nativeBuildInputs = [
      rustToolchain
      pkgs.llvmPackages.clang
      pkgs.llvmPackages.lld
    ];
  }
  ''
    mkdir -p $out/bin
    rustc --target ${redoxTarget} \
      --edition 2021 \
      -C panic=abort \
      -C target-cpu=x86-64 \
      -C linker=${clangBin} \
      -C link-arg=-nostdlib \
      -C link-arg=-static \
      -C link-arg=--target=${redoxTarget} \
      -C link-arg=${relibcDir}/lib/crt0.o \
      -C link-arg=${relibcDir}/lib/crti.o \
      -C link-arg=${relibcDir}/lib/crtn.o \
      -C link-arg=-Wl,--allow-multiple-definition \
      -L ${relibcDir}/lib \
      -L ${stubLibs}/lib \
      ${src} -o $out/bin/lld-wrapper
  ''
