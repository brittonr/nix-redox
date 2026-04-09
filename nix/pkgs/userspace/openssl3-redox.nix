# openssl3 - OpenSSL 3.x for Redox OS
#
# Cross-compiles upstream OpenSSL 3.x to x86_64-unknown-redox using the
# upstream Redox patch from the Redox cookbook. Produces static libssl/libcrypto
# plus headers for packages like OpenSSH.
#
# Source: https://github.com/openssl/openssl/releases
# Outputs: libssl.a, libcrypto.a, headers

{
  pkgs,
  lib,
  redoxTarget,
  relibc,
  openssl3-src,
  redox-zlib,
  redox-zstd,
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
  targetOs = builtins.elemAt (lib.splitString "-" redoxTarget) 2;
  targetName = "${targetOs}-${targetArch}";

  buildDeps = [
    redox-zlib
    redox-zstd
  ];
in
mkCLibrary.mkLibrary {
  pname = "redox-openssl3";
  version = "3.5.3";
  src = openssl3-src;

  nativeBuildInputs = [ pkgs.perl ];
  buildInputs = buildDeps;

  configurePhase = ''
    runHook preConfigure

    cp -r ${openssl3-src}/. .
    chmod -R u+w .

    patch -p1 < ${../patches/openssl3-redox.patch}

    ${mkCLibrary.crossEnvSetup}
    ${mkCLibrary.mkDepFlags buildDeps}

    # relibc's stdatomic.h trips clang's _Atomic handling; force OpenSSL to
    # skip the C11 stdatomic path and use its GCC/clang __atomic fallback.
    export CFLAGS="$CFLAGS -D__STDC_NO_ATOMICS__=1"
    export CXXFLAGS="$CXXFLAGS -D__STDC_NO_ATOMICS__=1"
    export CPPFLAGS="$CPPFLAGS -D__STDC_NO_ATOMICS__=1"
    export ARFLAGS=cr

    perl ./Configure \
      no-tests \
      no-unit-test \
      no-threads \
      zlib \
      enable-zstd \
      no-shared \
      no-dso \
      ${targetName} \
      --prefix=$out \
      --openssldir=$out/etc/ssl

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make -j1 build_generated libcrypto.a libssl.a
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib $out/include/openssl $out/lib/pkgconfig $out/etc/ssl
    cp libssl.a libcrypto.a $out/lib/
    cp include/openssl/*.h $out/include/openssl/

    cat > $out/lib/pkgconfig/openssl.pc << EOF
    prefix=$out
    libdir=\''${prefix}/lib
    includedir=\''${prefix}/include

    Name: OpenSSL
    Description: Secure Sockets Layer and cryptography libraries and tools
    Version: 3.5.3
    Requires: libssl libcrypto
  EOF

    cat > $out/lib/pkgconfig/libssl.pc << EOF
    prefix=$out
    libdir=\''${prefix}/lib
    includedir=\''${prefix}/include

    Name: OpenSSL-libssl
    Description: Secure Sockets Layer and cryptography libraries
    Version: 3.5.3
    Libs: -L\''${libdir} -lssl
    Cflags: -I\''${includedir}
  EOF

    cat > $out/lib/pkgconfig/libcrypto.pc << EOF
    prefix=$out
    libdir=\''${prefix}/lib
    includedir=\''${prefix}/include

    Name: OpenSSL-libcrypto
    Description: OpenSSL cryptography library
    Version: 3.5.3
    Libs: -L\''${libdir} -lcrypto -lz -lzstd
    Cflags: -I\''${includedir}
  EOF

    test -f $out/lib/libssl.a || { echo "ERROR: libssl.a not built"; exit 1; }
    test -f $out/lib/libcrypto.a || { echo "ERROR: libcrypto.a not built"; exit 1; }
    test -d $out/include/openssl || { echo "ERROR: OpenSSL headers missing"; exit 1; }

    runHook postInstall
  '';

  meta = with lib; {
    description = "OpenSSL 3.x static libraries for Redox OS";
    homepage = "https://www.openssl.org/";
    license = licenses.asl20;
  };
}
