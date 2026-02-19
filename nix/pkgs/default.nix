# Package aggregator for RedoxOS Nix build system
#
# This module provides a centralized entry point for all RedoxOS packages.
# It organizes packages into three categories:
# - host: Tools that run on the build machine (cookbook, redoxfs, installer)
# - system: Core OS components (relibc, kernel, bootloader, base)
# - userspace: Cross-compiled applications (ion, helix, binutils, etc.)
#
# Usage in flake.nix:
#   redoxPkgs = import ./nix/pkgs {
#     inherit pkgs lib;
#     inherit craneLib rustToolchain sysrootVendor;
#     inputs = { inherit relibc-src kernel-src ...; };
#   };
#
#   # Access packages:
#   inherit (redoxPkgs.host) cookbook redoxfs installer;
#   inherit (redoxPkgs.system) relibc kernel bootloader;
#   inherit (redoxPkgs.userspace) ion helix binutils;

{
  pkgs,
  lib,
  craneLib,
  rustToolchain,
  sysrootVendor,
  inputs,
  redoxTarget ? "x86_64-unknown-redox",
  # Optional: pass relibc from flake to avoid IFD issues with modular relibc
  relibc ? null,
}:

let
  # Import the shared library modules (with rustToolchain for sysroot support)
  redoxLib = import ../lib {
    inherit
      pkgs
      lib
      redoxTarget
      rustToolchain
      ;
  };

  # Common arguments passed to all package modules
  commonArgs = {
    inherit
      pkgs
      lib
      craneLib
      rustToolchain
      sysrootVendor
      redoxTarget
      ;
    inherit (redoxLib) stubLibs vendor;
  };

  # Host tools - run on build machine, no cross-compilation
  host = {
    cookbook = import ./host/cookbook.nix (
      commonArgs
      // {
        src = inputs.redox-src;
      }
    );

    redoxfs = import ./host/redoxfs.nix (
      commonArgs
      // {
        src = inputs.redoxfs-src;
      }
    );

    installer = import ./host/installer.nix (
      commonArgs
      // {
        src = inputs.installer-src;
      }
    );

    # Combined host tools
    fstools = pkgs.symlinkJoin {
      name = "redox-fstools";
      paths = [
        host.cookbook
        host.redoxfs
        host.installer
      ];
    };
  };

  # Use passed relibc if available (avoids IFD issues)
  # Otherwise build it from source
  resolvedRelibc =
    if relibc != null then
      relibc
    else
      import ./system/relibc.nix (
        commonArgs
        // {
          inherit (inputs)
            relibc-src
            openlibm-src
            compiler-builtins-src
            dlmalloc-rs-src
            ;
          inherit (inputs) cc-rs-src redox-syscall-src object-src;
        }
      );

  # System components - core OS requiring special build handling
  system = rec {
    relibc = resolvedRelibc;

    kernel = import ./system/kernel.nix (
      commonArgs
      // {
        inherit (inputs)
          kernel-src
          rmm-src
          redox-path-src
          fdt-src
          ;
      }
    );

    bootloader = import ./system/bootloader.nix (
      commonArgs
      // {
        inherit (inputs) bootloader-src uefi-src fdt-src;
      }
    );

    base = import ./system/base.nix (
      commonArgs
      // {
        inherit relibc;
        inherit (inputs)
          base-src
          liblibc-src
          orbclient-src
          rustix-redox-src
          drm-rs-src
          relibc-src
          redox-log-src
          fdt-src
          ;
      }
    );
  };

  # Userspace helper - creates cross-compiled packages with common settings
  mkUserspace = import ./userspace/mk-userspace.nix (
    commonArgs
    // {
      relibc = resolvedRelibc;
    }
  );

  # Get vendor from redoxLib for use in userspace packages
  inherit (redoxLib) vendor;

  # Userspace applications - cross-compiled for Redox target
  userspace = {
    ion = mkUserspace.mkBinary {
      pname = "ion-shell";
      src = inputs.ion-src;
      vendorHash = "sha256-PAi0x6MB0hVqUD1v1Z/PN7bWeAAKLxgcBNnS2p6InXs=";
      binaryName = "ion";
      preConfigure = ''
        echo "nix-build" > git_revision.txt
      '';
      gitSources = [
        {
          url = "git+https://gitlab.redox-os.org/redox-os/liner";
          git = "https://gitlab.redox-os.org/redox-os/liner";
        }
        {
          url = "git+https://gitlab.redox-os.org/redox-os/calc?rev=d2719efb67ab38c4c33ab3590822114453960da5";
          git = "https://gitlab.redox-os.org/redox-os/calc";
          rev = "d2719efb67ab38c4c33ab3590822114453960da5";
        }
        {
          url = "git+https://github.com/nix-rust/nix.git?rev=ff6f8b8a";
          git = "https://github.com/nix-rust/nix.git";
          rev = "ff6f8b8a";
        }
        {
          url = "git+https://gitlab.redox-os.org/redox-os/small";
          git = "https://gitlab.redox-os.org/redox-os/small";
        }
      ];
      meta = {
        description = "Ion Shell for Redox OS";
        homepage = "https://gitlab.redox-os.org/redox-os/ion";
        license = lib.licenses.mit;
      };
    };

    helix = mkUserspace.mkPackage {
      pname = "helix-editor";
      src = inputs.helix-src;
      vendorHash = "sha256-p82CxDgI6SNSfN1BTY/s8hLh7/nhg4UHFHA2b5vQZf0=";
      cargoBuildFlags = "--bin hx --manifest-path helix-term/Cargo.toml";
      # CC/CFLAGS are already set by mkPackage; only helix-specific env needed
      preBuild = ''
        export HELIX_DISABLE_AUTO_GRAMMAR_BUILD=1
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin
        cp target/${redoxTarget}/release/hx $out/bin/helix
        runHook postInstall
      '';
      gitSources = [
        {
          url = "git+https://github.com/nicholasbishop/helix-misc?branch=x86_64-unknown-redox";
          git = "https://github.com/nicholasbishop/helix-misc";
          branch = "x86_64-unknown-redox";
        }
        {
          url = "git+https://github.com/nicholasbishop/ropey?branch=x86_64-unknown-redox";
          git = "https://github.com/nicholasbishop/ropey";
          branch = "x86_64-unknown-redox";
        }
        {
          url = "git+https://github.com/nicholasbishop/gix?branch=x86_64-unknown-redox";
          git = "https://github.com/nicholasbishop/gix";
          branch = "x86_64-unknown-redox";
        }
        {
          url = "git+https://github.com/helix-editor/tree-sitter?rev=660481dbf71413eba5a928b0b0ab8da50c1109e0";
          git = "https://github.com/helix-editor/tree-sitter";
          rev = "660481dbf71413eba5a928b0b0ab8da50c1109e0";
        }
      ];
      meta = {
        description = "Helix Editor for Redox OS";
        homepage = "https://gitlab.redox-os.org/redox-os/helix";
        license = lib.licenses.mpl20;
      };
    };

    binutils = mkUserspace.mkPackage {
      pname = "redox-binutils";
      src = inputs.binutils-src;
      vendorHash = "sha256-RjHYE47M66f8vVAUINdi3yyB74nnKmzXuIHPc98QN5E=";
      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin
        cp target/${redoxTarget}/release/strings $out/bin/ 2>/dev/null || true
        cp target/${redoxTarget}/release/hex $out/bin/ 2>/dev/null || true
        cp target/${redoxTarget}/release/hexdump $out/bin/ 2>/dev/null || true
        runHook postInstall
      '';
      gitSources = [
        {
          url = "git+https://gitlab.redox-os.org/redox-os/libextra.git";
          git = "https://gitlab.redox-os.org/redox-os/libextra.git";
        }
      ];
      meta = {
        description = "Binary utilities (strings, hex, hexdump) for Redox OS";
        homepage = "https://gitlab.redox-os.org/redox-os/binutils";
        license = lib.licenses.mit;
      };
    };

    sodium = mkUserspace.mkPackage {
      pname = "sodium";
      src = inputs.sodium-src;
      vendorHash = "sha256-yuxAB+9CZHCz/bAKPD82+8LfU3vgVWU6KeTVVk1JcO8=";
      cargoBuildFlags = "--bin sodium --no-default-features --features ansi";
      preConfigure = ''
        # Patch orbclient to remove SDL dependency
        mkdir -p orbclient-patched
        cp -r ${inputs.orbclient-src}/* orbclient-patched/
        chmod -R u+w orbclient-patched/
        sed -i '/\[patch\.crates-io\]/,$d' orbclient-patched/Cargo.toml
        substituteInPlace Cargo.toml \
          --replace-fail 'orbclient = "0.3"' 'orbclient = { path = "orbclient-patched", default-features = false }'
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin
        cp target/${redoxTarget}/release/sodium $out/bin/
        runHook postInstall
      '';
      meta = {
        description = "Sodium: A vi-like text editor for Redox OS";
        homepage = "https://gitlab.redox-os.org/redox-os/sodium";
        license = lib.licenses.mit;
      };
    };

    netutils = mkUserspace.mkPackage {
      pname = "netutils";
      src = inputs.netutils-src;
      vendorHash = "sha256-bXjd6oVEl4GmxgNtGqYpAIvNH1u3to31jzlQlYKWD9Y=";
      preConfigure = ''
        # Patch nc to add -e/--exec support for spawning commands on connections
        cat > src/nc/main.rs << 'NC_MAIN'
        use std::env;
        use std::io::{self, Write};

        mod modes;
        use modes::*;

        static MAN_PAGE: &str = /* @MANSTART{nc} */
            r#"
        NAME
            nc - Concatenate and redirect sockets
        SYNOPSIS
            nc [[-h | --help] | [-u | --udp] | [-l | --listen] | [-e program | --exec program]] [hostname:port]
        DESCRIPTION
            Netcat (nc) is command line utility which can read and write data across network. Currently
            it only works with IPv4 and does not support any encryption.
        OPTIONS
            -h
            --help
                Print this manual page.
            -u
            --udp
                Use UDP instead of default TCP.

            -l
            --listen
                Listen for incoming connections.

            -e program
            --exec program
                Execute the specified program on accepted connections, with stdin/stdout/stderr
                connected to the network socket.
        AUTHOR
            Written by Sehny.
        "#; /* @MANEND */

        enum TransportProtocol {
            Tcp,
            Udp,
        }

        enum NcMode {
            Connect,
            Listen,
        }

        fn main() {
            let args: Vec<String> = env::args().skip(1).collect();
            let mut hostname = "".to_string();
            let mut exec_program: Option<String> = None;
            let mut proto = TransportProtocol::Tcp;
            let mut mode = NcMode::Connect;
            let mut stdout = io::stdout();
            let mut expect_exec = false;

            for arg in &args {
                if expect_exec {
                    exec_program = Some(arg.clone());
                    expect_exec = false;
                } else if arg.starts_with('-') {
                    match arg.as_str() {
                        "-h" | "--help" => {
                            stdout.write_all(MAN_PAGE.as_bytes()).unwrap();
                            return;
                        }
                        "-u" | "--udp" => proto = TransportProtocol::Udp,
                        "-l" | "--listen" => {
                            mode = NcMode::Listen;
                        }
                        "-e" | "--exec" => {
                            expect_exec = true;
                        }
                        _ => {
                            println!("Invalid argument!");
                            return;
                        }
                    }
                } else {
                    hostname = arg.clone();
                }
            }

            match (mode, proto) {
                (NcMode::Connect, TransportProtocol::Tcp) => {
                    connect_tcp(&hostname, exec_program.as_deref()).unwrap_or_else(|e| {
                        println!("nc error: {e}");
                    });
                }
                (NcMode::Listen, TransportProtocol::Tcp) => {
                    listen_tcp(&hostname, exec_program.as_deref()).unwrap_or_else(|e| {
                        println!("nc error: {e}");
                    });
                }
                (NcMode::Connect, TransportProtocol::Udp) => {
                    connect_udp(&hostname).unwrap_or_else(|e| {
                        println!("nc error: {e}");
                    });
                }
                (NcMode::Listen, TransportProtocol::Udp) => {
                    listen_udp(&hostname).unwrap_or_else(|e| {
                        println!("nc error: {e}");
                    });
                }
            }
        }
        NC_MAIN

        cat > src/nc/modes.rs << 'NC_MODES'
        use std::io::{stdin, Read, Write};
        use std::net::{TcpListener, TcpStream, UdpSocket};
        use std::os::fd::{AsRawFd, FromRawFd};
        use std::process::{exit, Command, Stdio};
        use std::str;
        use std::thread;

        macro_rules! print_err {
            ($($arg:tt)*) => (
                {
                    use std::io::prelude::*;
                    if let Err(e) = write!(&mut ::std::io::stderr(), "{}\n", format_args!($($arg)*)) {
                        panic!("Failed to write to stderr.\
                            \nOriginal error output: {}\
                            \nSecondary error writing to stderr: {}", format!($($arg)*), e);
                    }
                }
                )
        }

        const BUFFER_SIZE: usize = 65636;

        /// Read from the input file into a buffer in an infinite loop.
        /// Handle the buffer content with handler function.
        fn rw_loop<R, F>(input: &mut R, mut handler: F) -> !
        where
            R: Read,
            F: FnMut(&[u8], usize),
        {
            loop {
                let mut buffer = [0u8; BUFFER_SIZE];
                let count = match input.read(&mut buffer) {
                    Ok(0) => {
                        print_err!("End of input file/socket.");
                        exit(0);
                    }
                    Ok(c) => c,
                    Err(_) => {
                        print_err!("Error occurred while reading from file/socket.");
                        exit(1);
                    }
                };
                handler(&buffer, count);
            }
        }

        /// Use the rw_loop in both direction (TCP connection)
        fn both_dir_rw_loop(mut stream_read: TcpStream, mut stream_write: TcpStream) -> Result<(), String> {
            // Read loop
            thread::spawn(move || {
                rw_loop(&mut stream_read, |buffer, count| {
                    print!("{}", unsafe { str::from_utf8_unchecked(&buffer[..count]) });
                });
            });

            // Write loop
            let mut stdin = stdin();
            rw_loop(&mut stdin, |buffer, count| {
                let _ = stream_write.write(&buffer[..count]).unwrap_or_else(|e| {
                    print_err!("Error occurred while writing into socket: {e} ");
                    exit(1);
                });
            });
        }

        /// Spawn a program with the TCP stream as stdin/stdout/stderr
        fn exec_on_stream(program: &str, stream: TcpStream) -> Result<(), String> {
            let fd = stream.as_raw_fd();
            let stdin = unsafe { Stdio::from_raw_fd(fd) };
            let stdout_stream = stream.try_clone()
                .map_err(|e| format!("exec error: cannot clone stream for stdout ({e})"))?;
            let stdout = unsafe { Stdio::from_raw_fd(stdout_stream.as_raw_fd()) };
            let stderr_stream = stream.try_clone()
                .map_err(|e| format!("exec error: cannot clone stream for stderr ({e})"))?;
            let stderr = unsafe { Stdio::from_raw_fd(stderr_stream.as_raw_fd()) };

            let mut child = Command::new(program)
                .stdin(stdin)
                .stdout(stdout)
                .stderr(stderr)
                .spawn()
                .map_err(|e| format!("exec error: cannot spawn {program} ({e})"))?;

            // Forget the cloned streams so they aren't double-closed
            std::mem::forget(stdout_stream);
            std::mem::forget(stderr_stream);
            // Don't drop the original stream - fd is now owned by stdin Stdio
            std::mem::forget(stream);

            let status = child.wait()
                .map_err(|e| format!("exec error: wait failed ({e})"))?;

            if !status.success() {
                eprintln!("exec: {program} exited with {status}");
            }

            Ok(())
        }

        /// Connect to listening TCP socket
        pub fn connect_tcp(host: &str, exec_program: Option<&str>) -> Result<(), String> {
            let stream_read = TcpStream::connect(host)
                .map_err(|e| format!("connect_tcp error: cannot create socket ({e})"))?;

            let stream_write = stream_read
                .try_clone()
                .map_err(|e| format!("connect_tcp error: cannot create socket clone ({e})"))?;

            println!("Remote host: {host}");

            if let Some(program) = exec_program {
                return exec_on_stream(program, stream_read);
            }

            both_dir_rw_loop(stream_read, stream_write)
        }

        /// Listen on specified port and accept the first incoming connection
        pub fn listen_tcp(host: &str, exec_program: Option<&str>) -> Result<(), String> {
            let listener = TcpListener::bind(host)
                .map_err(|e| format!("listen_tcp error: cannot bind to specified port ({e})"))?;

            let (stream_read, socketaddr) = listener
                .accept()
                .map_err(|e| format!("listen_tcp error: cannot establish connection ({e})"))?;

            let stream_write = stream_read
                .try_clone()
                .map_err(|e| format!("listen_tcp error: cannot create socket clone ({e})"))?;

            eprintln!("Incoming connection from: {socketaddr}");

            if let Some(program) = exec_program {
                return exec_on_stream(program, stream_read);
            }

            both_dir_rw_loop(stream_read, stream_write)
        }

        pub fn connect_udp(host: &str) -> Result<(), String> {
            let socket = UdpSocket::bind("localhost:30000")
                .map_err(|e| format!("connect_udp error: could not bind to local socket ({e})"))?;

            socket
                .connect(host)
                .map_err(|e| format!("connect_udp error: could not set up remote socket ({e})"))?;

            let mut stdin = stdin();
            rw_loop(&mut stdin, |buffer, count| {
                socket.send(&buffer[..count]).unwrap_or_else(|e| {
                    eprintln!("Error occurred while writing into socket: {e}");
                    exit(1);
                });
            });
        }

        /// Listen for UDP datagrams on the specified socket
        pub fn listen_udp(host: &str) -> Result<(), String> {
            let socket = UdpSocket::bind(host)
                .map_err(|e| format!("connect_udp error: could not bind to local socket ({e})"))?;
            loop {
                let mut buffer = [0u8; BUFFER_SIZE];
                let count = match socket.recv_from(&mut buffer) {
                    Ok((0, _)) => {
                        print_err!("End of input file/socket.");
                        exit(0);
                    }
                    Ok((c, _)) => c,
                    Err(_) => {
                        print_err!("Error occurred while reading from file/socket.");
                        exit(1);
                    }
                };
                print!("{}", unsafe { str::from_utf8_unchecked(&buffer[..count]) });
            }
        }

        #[cfg(test)]
        mod tests {
            #[test]
            fn pass() {}
        }
        NC_MODES
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin
        for bin in dhcpd dns nc ping ifconfig; do
          if [ -f target/${redoxTarget}/release/$bin ]; then
            cp target/${redoxTarget}/release/$bin $out/bin/
          fi
        done
        runHook postInstall
      '';
      meta = {
        description = "Network utilities for Redox OS (dhcpd, dnsd, ping, ifconfig, nc)";
        homepage = "https://gitlab.redox-os.org/redox-os/netutils";
        license = lib.licenses.mit;
      };
    };

    # netcfg-setup - network configuration tool (replaces Ion scripts)
    netcfg-setup = import ./userspace/netcfg-setup.nix (
      commonArgs
      // {
        relibc = resolvedRelibc;
      }
    );

    # redoxfs compiled for Redox target (goes into initfs)
    redoxfsTarget = mkUserspace.mkPackage {
      pname = "redoxfs-target";
      src = inputs.redoxfs-src;
      vendorHash = "sha256-BXxNEwDIeMEpUFGBhSk1Q2lNG6h0n7/Kqm5RCsI8k0I=";
      cargoBuildFlags = "--bin redoxfs";
      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin
        cp target/${redoxTarget}/release/redoxfs $out/bin/
        runHook postInstall
      '';
      meta = {
        description = "Redox filesystem driver for Redox target";
        homepage = "https://gitlab.redox-os.org/redox-os/redoxfs";
        license = lib.licenses.mit;
      };
    };

    # Extrautils - extended utilities (grep, gzip, less, etc.)
    extrautils = import ./userspace/extrautils.nix (
      commonArgs
      // {
        inherit (inputs) extrautils-src filetime-src cc-rs-src;
        relibc = resolvedRelibc;
      }
    );

    uutils = mkUserspace.mkPackage {
      pname = "redox-uutils";
      version = "0.0.27";
      src = inputs.uutils-src;
      vendorHash = "sha256-Ucf4C9pXt2Gp125IwA3TuUWXTviHbyzhmfUX1GhuTko=";
      nativeBuildInputs = [ pkgs.jq ];
      cargoBuildFlags = "--features \"ls head cat echo mkdir touch rm cp mv pwd df du wc sort uniq\" --no-default-features";
      preConfigure = ''
        # Patch ctrlc to disable semaphore usage on Redox
        # This will be done after vendor-combined is created
      '';
      postConfigure = ''
                # Patch ctrlc after vendor merge
                if [ -d "vendor-combined/ctrlc" ]; then
                  rm -f vendor-combined/ctrlc/src/platform/unix/mod.rs
                  cat > vendor-combined/ctrlc/src/lib.rs << 'CTRLC_EOF'
        //! Cross-platform library for sending and receiving Unix signals (simplified for Redox)

        use std::sync::atomic::{AtomicBool, Ordering};

        #[derive(Debug)]
        pub enum Error {
            System(String),
        }

        impl std::fmt::Display for Error {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                match self {
                    Error::System(msg) => write!(f, "System error: {}", msg),
                }
            }
        }

        impl std::error::Error for Error {}

        static SHOULD_TERMINATE: AtomicBool = AtomicBool::new(false);

        /// Register a handler for Ctrl-C signals (no-op on Redox)
        pub fn set_handler<F>(_handler: F) -> Result<(), Error>
        where
            F: FnMut() + 'static + Send,
        {
            // Ctrl-C handling not supported on Redox
            Ok(())
        }

        /// Check if a Ctrl-C signal has been received (always false on Redox)
        pub fn check() -> bool {
            SHOULD_TERMINATE.load(Ordering::SeqCst)
        }
        CTRLC_EOF
                  # Regenerate checksum for patched ctrlc
                  ${pkgs.python3}/bin/python3 << 'PYTHON_PATCH'
        ${vendor.regenerateSingleCrateChecksum { crateDir = "vendor-combined/ctrlc"; }}
        PYTHON_PATCH
                fi
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin
        find target/${redoxTarget}/release -maxdepth 1 -type f -executable \
          ! -name "*.d" ! -name "*.rlib" \
          -exec cp {} $out/bin/ \;
        # Create symlinks for multicall binary
        if [ -f "$out/bin/coreutils" ]; then
          cd $out/bin
          for util in ls head cat echo mkdir touch rm cp mv pwd df du wc sort uniq; do
            ln -sf coreutils $util
          done
        fi
        runHook postInstall
      '';
      meta = {
        description = "Rust implementation of GNU coreutils for Redox OS";
        homepage = "https://github.com/uutils/coreutils";
        license = lib.licenses.mit;
      };
    };
  };

  # Infrastructure packages (initfs-tools, bootstrap, runner factories)
  infrastructure = import ./infrastructure {
    inherit
      pkgs
      lib
      rustToolchain
      sysrootVendor
      redoxTarget
      ;
    inherit (redoxLib) vendor;
    base-src = inputs.base-src;
    relibc-src = inputs.relibc-src;
    # Pass the host redoxfs tool for disk image creation
    redoxfs = host.redoxfs;
  };

in
{
  inherit
    host
    system
    userspace
    infrastructure
    ;

  # Convenience: flatten all packages for direct access
  all = host // system // userspace;

  # Re-export library for advanced use
  lib = redoxLib;
}
