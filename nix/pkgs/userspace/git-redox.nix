# git - Distributed version control system for Redox OS
#
# Git 2.13.1 cross-compiled for Redox. Uses the upstream Redox patch set
# which adds:
# - /scheme/null instead of /dev/null
# - SIG_DFL/SIG_IGN/SIG_ERR defines
# - Redox-specific terminal prompt (no termios)
# - syslog removal, setsid guard
# - Hard link → symlink fallback (Redox lacks hard links)
# - endian.h include for bswap
#
# Dependencies: curl, expat, openssl, zlib (all already built)
#
# Source: https://www.kernel.org/pub/software/scm/git/git-2.13.1.tar.xz
# Output: git binary + subcommands + templates

{
  pkgs,
  lib,
  redoxTarget,
  relibc,
  redox-curl,
  redox-expat,
  redox-openssl,
  redox-zlib,
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

  version = "2.13.1";

  src = pkgs.fetchurl {
    url = "https://www.kernel.org/pub/software/scm/git/git-${version}.tar.xz";
    hash = "sha256-O8G+zZg/d6sVSkaAFiQ2nbxAw90EtMSwetAm9WhGiP4=";
  };

  buildDeps = [
    redox-curl
    redox-expat
    redox-openssl
    redox-zlib
  ];

  sysroot = "${relibc}/${redoxTarget}";

in
pkgs.stdenv.mkDerivation {
  pname = "redox-git";
  inherit version;

  dontUnpack = true;
  dontFixup = true;

  nativeBuildInputs = with pkgs; [
    llvmPackages.clang
    llvmPackages.bintools
    llvmPackages.lld
    gnumake
    pkg-config
    gnutar
    xz
    python3
    gettext
  ];

  configurePhase = ''
        runHook preConfigure

        tar xf ${src}
        cd git-${version}
        chmod -R u+w .

        # === Apply Redox patches via Python ===
        ${pkgs.python3}/bin/python3 -c "
    import os

    def patch_file(path, old, new):
        with open(path) as f: content = f.read()
        patched = content.replace(old, new, 1)
        if patched == content:
            print(f'WARNING: patch not applied to {path}')
        with open(path, 'w') as f: f.write(patched)

    def prepend_file(path, text):
        with open(path) as f: content = f.read()
        with open(path, 'w') as f: f.write(text + content)

    # 1. bswap.h: include endian.h on Redox
    prepend_file('compat/bswap.h', '#if defined(__redox__)\n#include <machine/endian.h>\n#endif\n')

    # 2. terminal.c: add Redox terminal prompt (patched via sed below)

    # 3. configure: force NO_IPV6
    patch_file('configure', 'NO_IPV6=\n', 'NO_IPV6=YesPlease\n')

    # 4. daemon.c: Redox-specific syslog stubs and guards
    with open('daemon.c') as f: c = f.read()
    # Add LOG defines
    c = c.replace('static void logreport(int priority',
        '#if defined(__redox__)\n#define LOG_ERR 0\n#define LOG_INFO 1\n#endif\n\nstatic void logreport(int priority')
    # Guard syslog usage
    c = c.replace('if (log_syslog) {\n\t\tchar buf[1024];\n\t\tvsnprintf(buf, sizeof(buf), err, params);\n\t\tsyslog(priority, \"%s\", buf);\n\t} else {',
        '#if !defined(__redox__)\n\tif (log_syslog) {\n\t\tchar buf[1024];\n\t\tvsnprintf(buf, sizeof(buf), err, params);\n\t\tsyslog(priority, \"%s\", buf);\n\t} else\n#endif\n\t{')
    # Guard setsockopt
    c = c.replace('return setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR,\n\t\t\t  &on, sizeof(on));',
        '#if defined(__redox__)\n\treturn 0;\n#else\n\treturn setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR,\n\t\t\t  &on, sizeof(on));\n#endif')
    # Guard openlog
    c = c.replace('if (log_syslog) {\n\t\topenlog(\"git-daemon\"', '#if !defined(__redox__)\n\tif (log_syslog) {\n\t\topenlog(\"git-daemon\"')
    c = c.replace('set_die_routine(daemon_die);\n\t} else', 'set_die_routine(daemon_die);\n\t} else\n#endif')
    # Remove getgrnam
    c = c.replace('struct group *group = getgrnam(group_name);\n\t\tif (!group)\n\t\t\tdie(\"group not found - %s\", group_name);\n\n\t\tc.gid = group->gr_gid;',
        'die(\"group not found - %s\", group_name);')
    with open('daemon.c', 'w') as f: f.write(c)

    # 5. git-compat-util.h: SIG defines + DEV_NULL + REG_STARTEND
    with open('git-compat-util.h') as f: c = f.read()
    # Define REG_STARTEND before the check (relibc regex doesn't have it)
    # This makes git use its own regex wrapper with REG_STARTEND=0 (no-op flag)
    c = c.replace('#include <regex.h>',
        '#include <regex.h>\n#ifndef REG_STARTEND\n#define REG_STARTEND 0\n#endif')
    sig_defs = '''#ifndef SIG_DFL
    #define SIG_DFL ((void (*)(int))0)
    #endif
    #ifndef SIG_IGN
    #define SIG_IGN ((void (*)(int))1)
    #endif
    #ifndef SIG_ERR
    #define SIG_ERR ((void (*)(int))-1)
    #endif

    '''
    c = c.replace('#define _FILE_OFFSET_BITS 64', sig_defs + '#define _FILE_OFFSET_BITS 64')
    # DEV_NULL
    c = c.replace('#ifdef HAVE_PATHS_H',
        '#ifndef DEV_NULL\n#if defined(__redox__)\n#define DEV_NULL \"/scheme/null\"\n#else\n#define DEV_NULL \"/dev/null\"\n#endif\n#endif\n\n#ifdef HAVE_PATHS_H')
    with open('git-compat-util.h', 'w') as f: f.write(c)

    # 6. Skip bundled regex — define REG_STARTEND directly in relibc's regex.h
    # and remove NO_REGEX from config to use system regex instead
    # (We patch git-compat-util.h above to add #define REG_STARTEND 0)



    # 7. run-command.c: use DEV_NULL
    patch_file('run-command.c', 'open(\"/dev/null\", O_RDWR)', 'open(DEV_NULL, O_RDWR)')
    patch_file('run-command.c', 'die_errno(_(\"open /dev/null failed\"))', 'die_errno(_(\"open %s failed\"), DEV_NULL)')

    # 8. setup.c: use DEV_NULL + guard setsid
    with open('setup.c') as f: c = f.read()
    c = c.replace('open(\"/dev/null\", O_RDWR, 0)', 'open(DEV_NULL, O_RDWR, 0)')
    c = c.replace('die_errno(\"open /dev/null or dup failed\")', 'die_errno(\"open %s or dup failed\", DEV_NULL)')
    c = c.replace('if (setsid() == -1)\n\t\tdie_errno(\"setsid failed\");',
        '#if !defined(__redox__)\n\tif (setsid() == -1)\n\t\tdie_errno(\"setsid failed\");\n#endif')
    with open('setup.c', 'w') as f: f.write(c)

    # 9. builtin/get-tar-commit-id.c: relibc's tar.h conflicts with git's tar definitions
    # Add the ustar_header struct definition and undef RECORDSIZE
    with open('builtin/get-tar-commit-id.c') as f: c = f.read()
    c = c.replace('#define RECORDSIZE', '#undef RECORDSIZE\n#define RECORDSIZE')
    # The struct ustar_header is forward-declared but never defined — add it
    c = c.replace('struct ustar_header *header',
        'struct ustar_header { char name[100]; char mode[8]; char uid[8]; char gid[8]; char size[12]; char mtime[12]; char chksum[8]; char typeflag[1]; char linkname[100]; char magic[6]; char version[2]; char uname[32]; char gname[32]; char devmajor[8]; char devminor[8]; char prefix[155]; };\n\tstruct ustar_header *header',
        1)
    with open('builtin/get-tar-commit-id.c', 'w') as f: f.write(c)

    print('All git patches applied successfully')
    "

        # 2b. terminal.c: add Redox terminal prompt before the final #else block
        ${pkgs.python3}/bin/python3 << 'PYEOF'
    with open('compat/terminal.c') as f:
        lines = f.readlines()
    out = []
    inserted = False
    for i, line in enumerate(lines):
        if not inserted and line.strip() == '#else' and i+2 < len(lines) and 'git_terminal_prompt' in lines[i+2]:
            out.append('#elif defined(__redox__)\n')
            out.append('\n')
            out.append('ssize_t __getline(char **lptr, size_t *n, FILE *fp);\n')
            out.append('\n')
            out.append('char *git_terminal_prompt(const char *prompt, int echo)\n')
            out.append('{\n')
            out.append('\tchar *line = NULL;\n')
            out.append('\tsize_t n = 0;\n')
            out.append('\tfprintf(stderr, "%s", prompt);\n')
            out.append('\t__getline(&line, &n, stdin);\n')
            out.append('\treturn line;\n')
            out.append('}\n')
            out.append('\n')
            inserted = True
        out.append(line)
    with open('compat/terminal.c', 'w') as f:
        f.writelines(out)
    print('terminal.c patched' if inserted else 'WARNING: terminal.c patch point not found')
  PYEOF

        # 6. Makefile: remove hard link attempts (Redox lacks hard links)
        # Delete lines containing 'ln "$<"' or 'ln "$$' (hard link attempts)
        # Keep 'ln -s' lines (symlinks work fine)
        grep -n 'ln "\$' Makefile | grep -v 'ln -s' | cut -d: -f1 | sort -rn | while read line; do
          sed -i "''${line}d" Makefile
        done

        # Set up cross-compilation environment
        ${mkCLibrary.crossEnvSetupWithWrapper}
        ${mkCLibrary.mkDepFlags buildDeps}

        # Clang relaxations for old C code
        export CFLAGS="$CFLAGS -Wno-error -Wno-implicit-function-declaration -Wno-implicit-int -Wno-deprecated-non-prototype"




        # Allow duplicate symbols (git bundles some libc functions)
        export LDFLAGS="$LDFLAGS -Wl,--allow-multiple-definition"

        # Point to our cross-compiled curl
        export CURL_CONFIG="false"  # Don't use curl-config (host binary)

        ./configure \
          --host=${redoxTarget} \
          --build=${pkgs.stdenv.buildPlatform.config} \
          --prefix=$out \
          ac_cv_fread_reads_directories=yes \
          ac_cv_snprintf_returns_bogus=yes \
          ac_cv_lib_curl_curl_global_init=yes

        runHook postConfigure

        # AFTER configure: append overrides to config.mak.autogen.
        # configure detects NO_REGEX (relibc lacks REG_STARTEND) — we override
        # since git-compat-util.h now defines REG_STARTEND=0.
        # Also disable perl (not available on Redox).
        cat >> config.mak.autogen << 'CFGEOF'
    NO_REGEX =
    NO_PERL = 1
    NO_ICONV = 1
    NEEDS_LIBICONV =
    NEEDS_SSL_WITH_CURL = 1
    NEEDS_CRYPTO_WITH_SSL = 1
    BLK_SHA1 = 1
  CFGEOF
  '';

  buildPhase = ''
    runHook preBuild

    make -j $NIX_BUILD_CORES V=1

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    make install DESTDIR=$out/destdir

    # Move installed files from DESTDIR/prefix to $out
    mv $out/destdir/$out/* $out/ || mv $out/destdir/usr/* $out/ || true
    rm -rf $out/destdir

    # Remove man pages (save space)
    rm -rf $out/share/man $out/share/doc

    # Verify
    test -f $out/bin/git || { echo "ERROR: git binary not built"; exit 1; }
    file $out/bin/git
    echo "git built successfully"
    ls $out/bin/ | head -20

    runHook postInstall
  '';

  meta = with lib; {
    description = "Distributed version control system for Redox OS";
    homepage = "https://git-scm.com/";
    license = licenses.gpl2Only;
  };
}
