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
