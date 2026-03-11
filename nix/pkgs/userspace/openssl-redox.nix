# openssl - Cryptography and TLS library for Redox OS
#
# OpenSSL provides SSL/TLS and general-purpose cryptography.
# This uses the Redox-patched fork (v1 branch) from the Redox OS project.
#
# Unlocks: curl, git, openssh, python, and many network-enabled packages.
#
# Source: gitlab.redox-os.org/redox-os/openssl (Redox fork, v1 branch)
# Outputs: libssl.a, libcrypto.a, headers

{
  pkgs,
  lib,
  redoxTarget,
  relibc,
  openssl-redox-src,
  ...
}:

let
  mkCLibrary = import ./mk-c-library.nix {
    inherit
      pkgs
      lib
      redoxTarget
      relibc
      ;
  };

  targetArch = builtins.head (lib.splitString "-" redoxTarget);
  targetOs = "redox";

in
mkCLibrary.mkLibrary {
  pname = "redox-openssl";
  version = "1.1.1";
  src = openssl-redox-src;

  nativeBuildInputs = [ pkgs.perl ];

  configurePhase = ''
    runHook preConfigure

    cp -r ${openssl-redox-src}/* .
    chmod -R u+w .

    ${mkCLibrary.crossEnvSetup}

    # OpenSSL uses its own Configure script (Perl-based)
    # Extra args after the target are appended to CFLAGS, so only pass
    # compiler flags there — not Configure options like --with-rand-seed.
    perl ./Configure \
      threads \
      no-dgram \
      no-shared \
      ${targetOs}-${targetArch} \
      --prefix=$out \
      --openssldir=$out/etc/ssl \
      --cross-compile-prefix= \
      "-I${relibc}/${redoxTarget}/include" \
      "--sysroot=${relibc}/${redoxTarget}" \
      "--target=${redoxTarget}" \
      "-D__redox__" \
      "-U_FORTIFY_SOURCE" \
      "-D_FORTIFY_SOURCE=0"

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    # Generate headers first (opensslconf.h etc.)
    make -j $NIX_BUILD_CORES build_generated

    # Build the static libraries. The Makefile also tries to link
    # apps/openssl which fails (host ld, no libc), so we ignore errors
    # and verify the .a files exist afterward.
    make -j $NIX_BUILD_CORES libcrypto.a libssl.a || true

    # Verify the libraries were actually created
    test -f libcrypto.a || { echo "ERROR: libcrypto.a not built"; exit 1; }
    test -f libssl.a    || { echo "ERROR: libssl.a not built"; exit 1; }

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib $out/include/openssl $out/lib/pkgconfig

    cp libssl.a libcrypto.a $out/lib/
    cp include/openssl/*.h $out/include/openssl/

    # Generate pkgconfig files
    cat > $out/lib/pkgconfig/openssl.pc << EOF
    prefix=$out
    libdir=\''${prefix}/lib
    includedir=\''${prefix}/include

    Name: OpenSSL
    Description: Secure Sockets Layer and cryptography libraries and tools
    Version: 1.1.1
    Requires: libssl libcrypto
  EOF

    cat > $out/lib/pkgconfig/libssl.pc << EOF
    prefix=$out
    libdir=\''${prefix}/lib
    includedir=\''${prefix}/include

    Name: OpenSSL-libssl
    Description: Secure Sockets Layer and cryptography libraries
    Version: 1.1.1
    Libs: -L\''${libdir} -lssl
    Cflags: -I\''${includedir}
  EOF

    cat > $out/lib/pkgconfig/libcrypto.pc << EOF
    prefix=$out
    libdir=\''${prefix}/lib
    includedir=\''${prefix}/include

    Name: OpenSSL-libcrypto
    Description: OpenSSL cryptography library
    Version: 1.1.1
    Libs: -L\''${libdir} -lcrypto
    Cflags: -I\''${includedir}
  EOF

    runHook postInstall
  '';

  meta = with lib; {
    description = "Cryptography and TLS library for Redox OS";
    homepage = "https://gitlab.redox-os.org/redox-os/openssl";
    license = licenses.openssl;
  };
}
