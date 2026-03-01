# curl - HTTP client library and tool for Redox OS
#
# curl provides both libcurl (the transfer library) and the curl command-line
# tool. This builds both, cross-compiled to Redox.
#
# The only Redox-specific patch is a one-liner adding __redox__ to the
# sys/select.h include guard in curl.h (from the Redox fork: redox-8.6).
#
# Dependencies: zlib (compression), openssl (TLS)
# Outputs: libcurl.a, curl headers, curl binary, pkg-config
#
# Cross-compilation challenges solved:
# 1. Nix-wrapped clang picks up HOST glibc CRT → use -nostdlib + CC wrapper
#    that adds relibc CRT files (crt0.o/crti.o before, -lc/crtn.o after)
# 2. relibc's stdatomic.h is incompatible with clang's _Atomic(int) →
#    override ac_cv_header_stdatomic_h=no (falls through to pthread lock)
# 3. libtool rejects .o files in LDFLAGS → CRT lives in the CC wrapper,
#    not in LDFLAGS, so libtool never sees them
#
# Source: https://curl.se/ (upstream release tarball)

{
  pkgs,
  lib,
  redoxTarget,
  relibc,
  redox-zlib,
  redox-openssl,
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

  version = "8.11.1";

  src = pkgs.fetchurl {
    url = "https://curl.se/download/curl-${version}.tar.xz";
    hash = "sha256-x8p9tIsJCXQ+rvNCUNoCwZvGHU8dzt1mA/EJQJU2q1Y=";
  };

  # Extract tarball into a usable source directory
  extractedSrc = pkgs.stdenv.mkDerivation {
    name = "curl-${version}-src";
    dontUnpack = true;
    nativeBuildInputs = [
      pkgs.gnutar
      pkgs.xz
    ];
    installPhase = ''
      mkdir -p $out
      tar xf ${src} -C $out --strip-components=1
    '';
  };

  cc = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang";
  sysroot = "${relibc}/${redoxTarget}";

  buildDeps = [
    redox-zlib
    redox-openssl
  ];

  depCFlags = lib.concatMapStringsSep " " (d: "-I${d}/include") buildDeps;
  depLdFlags = lib.concatMapStringsSep " " (d: "-L${d}/lib") buildDeps;
  depPkgConfig = lib.concatMapStringsSep ":" (d: "${d}/lib/pkgconfig") buildDeps;

  # CC wrapper script that handles CRT startup files transparently.
  # - Compile-only (-c, -S, -E): pass through to real clang
  # - Link step: prepend crt0.o+crti.o, append -lc+crtn.o
  # This keeps LDFLAGS clean so libtool doesn't choke on .o files.
  ccWrapper = pkgs.writeShellScript "redox-cc" ''
    # Detect compile-only operations
    for arg in "$@"; do
      case "$arg" in
        -c|-S|-E|-M|-MM)
          exec ${cc} "$@"
          ;;
      esac
    done
    # Link step: add relibc CRT startup files
    # -static: libtool strips this from LDFLAGS, so we force it here
    # -l:libc.a: force static libc (sysroot has both libc.a and libc.so)
    exec ${cc} -static ${sysroot}/lib/crt0.o ${sysroot}/lib/crti.o "$@" -l:libc.a -l:libpthread.a ${sysroot}/lib/crtn.o
  '';

in
mkCLibrary.mkLibrary {
  pname = "redox-curl";
  inherit version;
  src = extractedSrc;

  nativeBuildInputs = [
    pkgs.perl # OpenSSL detection and doc scripts
    pkgs.python3 # cd2nroff script
  ];
  buildInputs = buildDeps;

  configurePhase = ''
    runHook preConfigure

    cp -r ${extractedSrc}/* .
    chmod -R u+w .

    # Apply the Redox patch: add __redox__ to sys/select.h include guard
    # (from gitlab.redox-os.org/redox-os/curl, branch redox-8.6, commit f50c2839)
    sed -i '/defined(__CYGWIN__).*AMIGA/i\    defined(__redox__) || \\' include/curl/curl.h
    grep -q '__redox__' include/curl/curl.h || { echo "ERROR: Redox patch failed"; exit 1; }

    # Fix shebangs for Nix sandbox (scripts use #!/usr/bin/env which doesn't exist)
    patchShebangs scripts/ 2>/dev/null || true

    ${mkCLibrary.crossEnvSetup}

    # Override CC with our wrapper that handles CRT startup files
    export CC="${ccWrapper}"

    # Add dependency include paths
    export CFLAGS="$CFLAGS ${depCFlags}"
    export CPPFLAGS="$CPPFLAGS ${depCFlags}"

    # LDFLAGS: no CRT files here (handled by CC wrapper), no -nostdlib needed
    # since the wrapper adds CRT explicitly. Keep -static and link paths.
    export LDFLAGS="--target=${redoxTarget} --sysroot=${sysroot} -L${sysroot}/lib ${depLdFlags} -nostdlib -static -fuse-ld=lld"

    export LIBS=""

    # pkg-config for zlib and openssl detection
    export PKG_CONFIG_LIBDIR="${depPkgConfig}:${sysroot}/lib/pkgconfig"

    # ac_cv_header_stdatomic_h=no: relibc's stdatomic.h is incompatible with
    # clang's _Atomic(int) builtins. Curl's easy_lock.h falls through to
    # the pthreads path (relibc has libpthread).
    ./configure \
      ac_cv_header_stdatomic_h=no \
      --host=${redoxTarget} \
      --build=${pkgs.stdenv.buildPlatform.config} \
      --prefix=$out \
      --enable-static \
      --disable-shared \
      --disable-ftp \
      --disable-ipv6 \
      --disable-ntlm-wb \
      --disable-tftp \
      --disable-threaded-resolver \
      --disable-ldap \
      --disable-ldaps \
      --disable-dict \
      --disable-gopher \
      --disable-imap \
      --disable-mqtt \
      --disable-pop3 \
      --disable-rtsp \
      --disable-smb \
      --disable-smtp \
      --disable-telnet \
      --with-ssl=${redox-openssl} \
      --with-zlib=${redox-zlib} \
      --with-ca-path=/etc/ssl/certs \
      --without-libpsl \
      --without-brotli \
      --without-zstd \
      --without-nghttp2 \
      --without-libidn2 \
      --without-libssh2 \
      --without-librtmp

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make -j $NIX_BUILD_CORES
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    make install

    # Verify outputs
    test -f $out/lib/libcurl.a || { echo "ERROR: libcurl.a not built"; exit 1; }
    test -f $out/bin/curl      || { echo "ERROR: curl binary not built"; exit 1; }

    # Verify it's a Redox ELF
    file $out/bin/curl

    runHook postInstall
  '';

  meta = with lib; {
    description = "HTTP client library and tool for Redox OS";
    homepage = "https://curl.se/";
    license = licenses.curl;
  };
}
