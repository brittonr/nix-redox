# openssh - OpenSSH portable for Redox OS
#
# Cross-compiles OpenSSH 9.8p1 using the upstream Redox patch carried in the
# Redox cookbook. Produces ssh, sshd, ssh-keygen, scp, sftp, and sftp-server.

{
  pkgs,
  lib,
  redoxTarget,
  relibc,
  openssh-src,
  redox-openssl3,
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

  buildDeps = [
    redox-openssl3
    redox-zlib
    redox-zstd
  ];
in
pkgs.stdenv.mkDerivation {
  pname = "openssh-redox";
  version = "9.8p1";

  src = openssh-src;
  dontUnpack = true;
  dontFixup = true;

  nativeBuildInputs = with pkgs; [
    llvmPackages.clang
    llvmPackages.bintools
    llvmPackages.lld
    gnumake
    pkg-config
    gnutar
    gzip
    perl
  ];

  configurePhase = ''
    runHook preConfigure

    cp -r ${openssh-src}/. .
    chmod -R u+w .

    patch -p1 < ${../patches/openssh-redox.patch}

    ${pkgs.python3}/bin/python3 - <<'PYEOF'
    import re
    from pathlib import Path

    path = Path("openbsd-compat/getrrsetbyname.c")
    text = path.read_text()
    pattern = r"typedef struct __res_state \*res_state;\n(#endif /\* __redox ?\*/\n)"
    replacement = """typedef struct __res_state *res_state;\n\nstatic int\nres_query(const char *dname, int class, int type, unsigned char *answer, int anslen)\n{\n    (void)dname;\n    (void)class;\n    (void)type;\n    (void)answer;\n    (void)anslen;\n    return -1;\n}\n\n\\1"""
    new_text, count = re.subn(pattern, replacement, text, count=1)
    if count != 1:
        raise SystemExit("failed to find Redox resolver stub insertion point")
    path.write_text(new_text)

    servconf = Path("servconf.c")
    servconf_text = servconf.read_text()
    old = '{ "usepam", sUnsupported, SSHCFG_GLOBAL },'
    new = '{ "usepam", sIgnore, SSHCFG_GLOBAL },'
    if old not in servconf_text:
        raise SystemExit("failed to find UsePAM unsupported entry")
    servconf.write_text(servconf_text.replace(old, new, 1))
    PYEOF

    ${mkCLibrary.crossEnvSetupWithWrapper}
    ${mkCLibrary.mkDepFlags buildDeps}

    export CFLAGS="$CFLAGS -DSYSTEMD_NOTIFY=1"
    export LIBS="-lz -lzstd"

    ./configure \
      --host=${redoxTarget} \
      --build=${pkgs.stdenv.buildPlatform.config} \
      --prefix=/usr \
      --sysconfdir=/etc/ssh \
      --disable-strip \
      --with-ssl-dir=${redox-openssl3} \
      --with-zlib=${redox-zlib}

    # Nix store outputs cannot carry setuid bits. ssh-keysign is still built,
    # but install it as a normal executable inside the package output.
    sed -i 's/-m 4711/-m 0755/g' Makefile

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make -j1
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    make install DESTDIR=$out/stage

    mkdir -p $out/bin $out/usr
    if [ -f $out/stage/usr/sbin/sshd ]; then
      mv $out/stage/usr/sbin/sshd $out/stage/usr/bin/sshd
      rmdir $out/stage/usr/sbin || true
    fi
    if [ -f $out/stage/usr/libexec/sftp-server ]; then
      mv $out/stage/usr/libexec/sftp-server $out/stage/usr/bin/sftp-server
    fi

    cp -r $out/stage/usr/. $out/usr/
    rm -rf $out/stage

    for bin in ssh sshd ssh-keygen scp sftp sftp-server ssh-add ssh-agent ssh-keyscan; do
      if [ -f $out/usr/bin/$bin ]; then
        cp $out/usr/bin/$bin $out/bin/$bin
      fi
    done

    test -f $out/bin/ssh || { echo "ERROR: ssh missing"; exit 1; }
    test -f $out/bin/sshd || { echo "ERROR: sshd missing"; exit 1; }
    test -f $out/bin/ssh-keygen || { echo "ERROR: ssh-keygen missing"; exit 1; }
    test -f $out/bin/scp || { echo "ERROR: scp missing"; exit 1; }
    test -f $out/bin/sftp || { echo "ERROR: sftp missing"; exit 1; }
    test -f $out/bin/sftp-server || { echo "ERROR: sftp-server missing"; exit 1; }

    runHook postInstall
  '';

  meta = with lib; {
    description = "OpenSSH portable cross-compiled for Redox OS";
    homepage = "https://www.openssh.com/portable.html";
    license = licenses.bsd2;
  };
}
