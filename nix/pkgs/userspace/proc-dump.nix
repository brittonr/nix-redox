# proc-dump: Process state diagnostic tool for Redox OS
#
# Reads /scheme/proc/ to list all running processes with their state
# (blocked/running) and open file descriptors. Used by the parallel
# build test to capture process state when a cargo JOBS>1 hang is
# detected.
#
# Output goes to a file argument to avoid perturbing pipe state
# that may be causing the hang under investigation.
#
# Cross-compiled for Redox using rustc directly (single-file, no cargo).

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

  src = pkgs.writeText "proc-dump-main.rs" ''
    //! proc-dump: Dump process state from /scheme/proc/ on Redox OS
    //!
    //! For each PID found, reads:
    //!   /scheme/proc/<pid>/status  — blocked/running state
    //!   /scheme/proc/<pid>/filetable — open file descriptors
    //!
    //! Output is written to the file path given as argv[1], or stdout if none.

    use std::env;
    use std::fs;
    use std::io::Write;

    fn read_file_lossy(path: &str) -> String {
        match fs::read(path) {
            Ok(bytes) => String::from_utf8_lossy(&bytes).trim().to_string(),
            Err(e) => format!("<error: {}>", e),
        }
    }

    fn dump_procs(out: &mut dyn Write) {
        let _ = writeln!(out, "=== proc-dump: process state snapshot ===");
        let _ = writeln!(out, "");

        let entries = match fs::read_dir("/scheme/proc/") {
            Ok(e) => e,
            Err(e) => {
                let _ = writeln!(out, "ERROR: cannot read /scheme/proc/: {}", e);
                return;
            }
        };

        let mut pids: Vec<String> = Vec::new();
        for entry in entries {
            if let Ok(entry) = entry {
                let name = entry.file_name().to_string_lossy().to_string();
                // PIDs are numeric directory entries
                if name.chars().all(|c| c.is_ascii_digit()) {
                    pids.push(name);
                }
            }
        }
        pids.sort_by_key(|p| p.parse::<u64>().unwrap_or(0));

        let _ = writeln!(out, "Total processes: {}", pids.len());
        let _ = writeln!(out, "");

        for pid in &pids {
            let _ = writeln!(out, "--- PID {} ---", pid);

            // Read process status (blocked/running/etc.)
            let status_path = format!("/scheme/proc/{}/status", pid);
            let status = read_file_lossy(&status_path);
            let _ = writeln!(out, "  status: {}", status);

            // Read open file descriptors
            let filetable_path = format!("/scheme/proc/{}/filetable", pid);
            let filetable = read_file_lossy(&filetable_path);
            if !filetable.is_empty() && !filetable.starts_with("<error") {
                let _ = writeln!(out, "  filetable:");
                for line in filetable.lines() {
                    let _ = writeln!(out, "    {}", line);
                }
            } else {
                let _ = writeln!(out, "  filetable: {}", filetable);
            }

            // Read process name/exe if available
            let name_path = format!("/scheme/proc/{}/exe", pid);
            let exe = read_file_lossy(&name_path);
            if !exe.is_empty() && !exe.starts_with("<error") {
                let _ = writeln!(out, "  exe: {}", exe);
            }

            let _ = writeln!(out, "");
        }

        let _ = writeln!(out, "=== proc-dump: end ===");
    }

    fn main() {
        let args: Vec<String> = env::args().collect();

        if args.len() > 1 && (args[1] == "-h" || args[1] == "--help") {
            eprintln!("Usage: proc-dump [output-file]");
            eprintln!("  Dumps process state from /scheme/proc/ to file or stdout.");
            return;
        }

        if args.len() > 1 {
            match fs::File::create(&args[1]) {
                Ok(mut f) => dump_procs(&mut f),
                Err(e) => {
                    eprintln!("proc-dump: cannot create {}: {}", args[1], e);
                    std::process::exit(1);
                }
            }
        } else {
            let stdout = std::io::stdout();
            let mut handle = stdout.lock();
            dump_procs(&mut handle);
        }
    }
  '';
in
pkgs.runCommand "proc-dump"
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
      ${src} -o $out/bin/proc-dump
  ''
