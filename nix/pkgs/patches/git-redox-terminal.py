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
