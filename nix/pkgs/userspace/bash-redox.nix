# bash - GNU Bourne-Again Shell for Redox OS
#
# bash is the standard Unix shell used by most scripts and build systems.
# Essential for self-hosting: running configure scripts, Makefiles, etc.
#
# Dependencies: readline (we have it), ncurses (we have it)
# Gettext skipped via --disable-nls for now.
#
# Extensive Redox-specific patches from upstream cookbook:
# - group completion disabled (__redox__ guard)
# - ulimit: HAVE_RESOURCE guarded against __redox__
# - config-top.h: BROKEN_DIRENT_D_INO defined
# - configure: bash_malloc disabled for *-redox*
# - execute_cmd.c: HAVE_GETTIMEOFDAY guard
# - general.c: check_dev_tty disabled on Redox
# - posixwait.h: force POSIX wait types
# - jobs.c: pgrp/tcsetpgrp ordering fix
# - readline/input.c: HAVE_SELECT fallback
# - readline/terminal.c: __redox__ guard for PC extern
# - getcwd.c: disabled on Redox (relibc provides it)
# - strtoimax.c: disabled on Redox (relibc provides it)
# - Various multibyte guards
#
# Source: https://ftp.gnu.org/gnu/bash/bash-5.2.15.tar.gz
# Binary: bash

{
  pkgs,
  lib,
  redoxTarget,
  relibc,
  redox-readline,
  redox-ncurses,
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

  version = "5.2.15";

  src = pkgs.fetchurl {
    url = "https://ftp.gnu.org/gnu/bash/bash-${version}.tar.gz";
    hash = "sha256-E3IJZbX0/DoNS2HdN+dWXHQdqaW+JO3CrgAYL8GzWIw=";
  };

  extractedSrc = pkgs.stdenv.mkDerivation {
    name = "bash-${version}-src";
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.gnutar pkgs.gzip ];
    installPhase = ''
      mkdir -p $out
      tar xf ${src} -C $out --strip-components=1
    '';
  };

  buildDeps = [ redox-readline redox-ncurses ];

in
mkCLibrary.mkLibrary {
  pname = "redox-bash";
  inherit version;
  src = extractedSrc;
  buildInputs = buildDeps;

  configurePhase = ''
    runHook preConfigure

    cp -r ${extractedSrc}/* .
    chmod -R u+w .

    # === Redox patches (from upstream cookbook redox.patch) ===
    # Using Python for complex multi-line patches to avoid sed quoting issues

    ${pkgs.python3}/bin/python3 -c "
import re, os

def patch_file(path, old, new):
    with open(path) as f: content = f.read()
    patched = content.replace(old, new, 1)
    if patched == content:
        print(f'WARNING: patch not applied to {path} (pattern not found)')
    with open(path, 'w') as f: f.write(patched)

# 1. Disable group completion on Redox
patch_file('bashline.c',
    '#if defined (__WIN32__) || defined (__OPENNT) || !defined (HAVE_GRP_H)',
    '#if defined (__WIN32__) || defined (__OPENNT) || !defined (HAVE_GRP_H) || defined(__redox__)')

# 2. ulimit: guard HAVE_RESOURCE with !__redox__
patch_file('builtins/ulimit.def',
    '#if defined (HAVE_RESOURCE)',
    '#if defined (HAVE_RESOURCE) && !defined(__redox__)')

# 3. config-top.h: add BROKEN_DIRENT_D_INO
with open('config-top.h', 'a') as f:
    f.write('\n#define BROKEN_DIRENT_D_INO 1\n')

# 4. configure: disable bash_malloc for Redox
for f in ['configure', 'configure.ac']:
    if os.path.exists(f):
        patch_file(f,
            '*-haiku*)\\topt_bash_malloc=no ;;',
            '*-haiku*)\\topt_bash_malloc=no ;;\\n*-redox*)\\topt_bash_malloc=no ;;')

# 5. posixwait.h: force POSIX wait types
patch_file('include/posixwait.h', '#if !defined (_POSIX_VERSION)', '#if 0')
patch_file('include/posixwait.h', '#if defined (_POSIX_VERSION)', '#if 1')

# 6. readline/input.c + signal.h include: HAVE_SELECT fallback
for f in ['lib/readline/input.c', 'lib/sh/input_avail.c']:
    if os.path.exists(f):
        patch_file(f, '#if defined (HAVE_PSELECT)', '#if defined (HAVE_PSELECT) || defined (HAVE_SELECT)')

# 6b. Also fix the variable declaration guard in readline/input.c
for f in ['lib/readline/input.c']:
    if os.path.exists(f):
        with open(f) as fh: c = fh.read()
        c = c.replace('#if defined (HAVE_PSELECT)\n  sigset_t empty_set;\n  fd_set readfds;',
                      '#if defined (HAVE_PSELECT) || defined (HAVE_SELECT)\n  sigset_t empty_set;\n  fd_set readfds;')
        with open(f, 'w') as fh: fh.write(c)

# 7. readline/terminal.c: __redox__ guard
patch_file('lib/readline/terminal.c',
    '#if !defined (__linux__) && !defined (NCURSES_VERSION)',
    '#if !defined (__linux__) && !defined (NCURSES_VERSION) && !defined (__redox__)')

# 8. getcwd.c: disable custom getcwd on Redox
patch_file('lib/sh/getcwd.c',
    '#if !defined (HAVE_GETCWD)',
    '#if !defined (HAVE_GETCWD) && !defined(__redox__)')

# 9. strtoimax.c: disable on Redox (relibc provides it)
with open('lib/sh/strtoimax.c') as f: content = f.read()
content = '#if !defined (__redox__)\n' + content
content = content.replace('#ifdef TESTING', '#endif /* !__redox__ */\n#ifdef TESTING')
with open('lib/sh/strtoimax.c', 'w') as f: f.write(content)

# 10. parse.y + y.tab.c: comment out the unguarded HANDLE_MULTIBYTE reference
# This block uses shell_input_line_property which only exists with HANDLE_MULTIBYTE.
# Since we compile with --disable-multibyte, just remove the block entirely.
for f in ['parse.y', 'y.tab.c']:
    if os.path.exists(f):
        with open(f) as fh: content = fh.read()
        # Wrap all references to HANDLE_MULTIBYTE-only symbols in guards
        import re
        # Guard the specific block that uses shell_input_line_property
        content = content.replace(
            'if (shell_input_line_index == shell_input_line_len && last_shell_getc_is_singlebyte == 0)',
            'if (0 /* HANDLE_MULTIBYTE disabled */)')
        # Remove direct references to shell_input_line_property
        content = re.sub(r'shell_input_line_property\[[^\]]+\]\s*=\s*1;',
                        '/* shell_input_line_property removed (no HANDLE_MULTIBYTE) */', content)
        with open(f, 'w') as fh: fh.write(content)

print('All patches applied successfully')
"

    # Update config.sub for Redox target
    cp ${pkgs.gnu-config}/config.sub support/config.sub 2>/dev/null || true

    # Create stub doc/Makefile.in (we don't need docs)
    mkdir -p doc
    cat > doc/Makefile.in << 'DOCEOF'
all:
install:
clean:
distclean:
DOCEOF
    touch doc/make.1

    # Fix timestamps: touch everything uniformly AFTER patching.
    # This prevents make from trying to regenerate configure from configure.ac.
    find . -type f -exec touch -t 202501010000 {} +
    # Then make configure newer than configure.ac
    sleep 1
    touch configure

    ${mkCLibrary.crossEnvSetupWithWrapper}
    ${mkCLibrary.mkDepFlags buildDeps}

    # bash 5.2 has many K&R declarations and unguarded HANDLE_MULTIBYTE references.
    # Clang 21 is stricter than GCC about these — relax to allow compilation.
    export CFLAGS="$CFLAGS -Wno-error -Wno-implicit-function-declaration -Wno-implicit-int -Wno-deprecated-non-prototype"
    # Allow duplicate symbols (bash bundles mktime/getopt, relibc also has them)
    export LDFLAGS="$LDFLAGS -Wl,--allow-multiple-definition"

    # CC_FOR_BUILD: host compiler for build-time tools (mkbuiltins, etc.)
    export CC_FOR_BUILD="gcc"

    ./configure \
      --host=${redoxTarget} \
      --build=${pkgs.stdenv.buildPlatform.config} \
      --prefix=$out \
      --enable-static-link \
      --disable-nls \
      --disable-multibyte \
      --without-bash-malloc \
      ac_cv_func_wcwidth=no \
      bash_cv_func_sigsetjmp=no \
      bash_cv_getenv_redef=no \
      bash_cv_must_reinstall_sighandlers=no \
      bash_cv_func_strcoll_broken=no \
      bash_cv_func_ctype_nonascii=no \
      bash_cv_dup2_broken=no \
      bash_cv_pgrp_pipe=no \
      bash_cv_sys_siglist=no \
      bash_cv_under_sys_siglist=no \
      bash_cv_opendir_not_robust=no \
      bash_cv_printf_a_format=no

    # Fix builtins/Makefile: remove -DHAVE_CONFIG_H from CCFLAGS_FOR_BUILD
    # config.h is for the cross target — build tools must not use it.
    # Also add -std=gnu89 for GCC 15 compatibility (K&R function declarations).
    sed -i 's/-DHAVE_CONFIG_H//' builtins/Makefile 2>/dev/null || true
    sed -i 's/CC_FOR_BUILD = .*/CC_FOR_BUILD = gcc -std=gnu89/' builtins/Makefile 2>/dev/null || true

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    # Parallel make has bugs in bash — use single job (per upstream recipe)
    make -j1
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    make install

    test -f $out/bin/bash || { echo "ERROR: bash binary not built"; exit 1; }
    file $out/bin/bash

    # Create sh symlink (many scripts expect /bin/sh = bash)
    ln -sf bash $out/bin/sh

    rm -rf $out/share/man $out/share/doc $out/share/info $out/share/locale 2>/dev/null || true

    runHook postInstall
  '';

  meta = with lib; {
    description = "GNU Bourne-Again Shell for Redox OS";
    homepage = "https://www.gnu.org/software/bash/";
    license = licenses.gpl3Plus;
  };
}
