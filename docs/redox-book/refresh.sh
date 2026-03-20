#!/usr/bin/env bash
# Refresh the local Redox OS book mirror from doc.redox-os.org
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAGES_DIR="$SCRIPT_DIR/pages"
HTML_DIR="$(mktemp -d)"
BASE="https://doc.redox-os.org/book"

trap 'rm -rf "$HTML_DIR"' EXIT

pages=(
  introduction introducing-redox our-goals philosophy why-a-new-os
  why-rust redox-use-cases how-redox-compares influences hardware-support
  important-programs side-projects system-design microkernels boot-process
  kernel user-space communication memory scheduling drivers redoxfs
  graphics-windowing security features package-management schemes-resources
  scheme-rooted-paths resources schemes everything-is-a-file
  stitching-it-all-together scheme-operation event-scheme example
  programs-libraries components gui shell system-tools getting-started
  running-vm real-hardware installing trying-out-redox tasks pkg
  contributing chat best-practices literate-programming writing-docs-correctly
  style rusting-properly avoiding-panics testing-practices using-redox-gitlab
  signing-in-to-gitlab repository-structure creating-proper-bug-reports
  creating-proper-pull-requests filing-issues build-process podman-build
  building-redox nothing-to-hello-world configuration-settings
  build-system-reference advanced-podman-build advanced-build i686 aarch64
  raspi troubleshooting build-phases developing-for-redox developer-faq
  references libraries-apis coding-and-building including-programs
  porting-applications porting-case-study ci performance syscall-debug
  quick-workflow asking-questions
)

echo "Fetching ${#pages[@]} pages from $BASE ..."
failed=()
for page in "${pages[@]}"; do
  if ! curl -sS -f -o "$HTML_DIR/${page}.html" --max-time 15 "$BASE/${page}.html" 2>/dev/null; then
    failed+=("$page")
  fi
  sleep 0.1
done

if [ ${#failed[@]} -gt 0 ]; then
  echo "WARNING: Failed to fetch: ${failed[*]}"
fi

echo "Converting HTML to markdown ..."
python3 - "$HTML_DIR" "$PAGES_DIR" <<'PYEOF'
import os, re, sys
from html.parser import HTMLParser

class MDBookExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self.in_content = False
        self.skip_depth = 0
        self.text_parts = []
        self.tag_stack = []
        self.in_pre = False
        self.in_code = False
        self.list_depth = 0
        self.in_table = False
        self.table_row = []
        self.table_rows = []

    def handle_starttag(self, tag, attrs):
        attrs_dict = dict(attrs)
        if tag == 'main':
            self.in_content = True; return
        if not self.in_content: return
        if tag == 'nav':
            self.skip_depth += 1; return
        if self.skip_depth > 0: return
        self.tag_stack.append(tag)
        if tag in ('h1','h2','h3','h4','h5','h6'):
            self.text_parts.append('\n' + '#' * int(tag[1]) + ' ')
        elif tag == 'p': self.text_parts.append('\n\n')
        elif tag == 'br': self.text_parts.append('\n')
        elif tag == 'pre':
            self.in_pre = True; self.text_parts.append('\n```\n')
        elif tag == 'code' and not self.in_pre:
            self.in_code = True; self.text_parts.append('`')
        elif tag in ('ul','ol'):
            self.list_depth += 1; self.text_parts.append('\n')
        elif tag == 'li':
            self.text_parts.append(f"\n{'  '*(self.list_depth-1)}- ")
        elif tag == 'a':
            href = attrs_dict.get('href','')
            if href and not href.startswith('#') and 'class' not in attrs_dict:
                self.text_parts.append('[')
        elif tag in ('strong','b'): self.text_parts.append('**')
        elif tag in ('em','i'):
            if attrs_dict.get('class','') != 'fa fa-angle-right':
                self.text_parts.append('*')
        elif tag == 'table':
            self.in_table = True; self.table_rows = []
        elif tag == 'tr': self.table_row = []
        elif tag == 'blockquote': self.text_parts.append('\n> ')

    def handle_endtag(self, tag):
        if tag == 'main': self.in_content = False; return
        if tag == 'nav' and self.skip_depth > 0: self.skip_depth -= 1; return
        if not self.in_content or self.skip_depth > 0: return
        if self.tag_stack and self.tag_stack[-1] == tag: self.tag_stack.pop()
        if tag in ('h1','h2','h3','h4','h5','h6'): self.text_parts.append('\n')
        elif tag == 'pre':
            self.in_pre = False; self.text_parts.append('\n```\n')
        elif tag == 'code' and not self.in_pre:
            self.in_code = False; self.text_parts.append('`')
        elif tag in ('ul','ol'): self.list_depth = max(0, self.list_depth-1)
        elif tag in ('strong','b'): self.text_parts.append('**')
        elif tag in ('em','i'): self.text_parts.append('*')
        elif tag == 'table':
            self.in_table = False
            if self.table_rows:
                max_cols = max(len(r) for r in self.table_rows)
                col_widths = [0]*max_cols
                for row in self.table_rows:
                    for i,cell in enumerate(row):
                        col_widths[i] = max(col_widths[i], len(cell))
                lines = []
                for ri,row in enumerate(self.table_rows):
                    cells = [cell.ljust(col_widths[i]) for i,cell in enumerate(row)]
                    while len(cells) < max_cols: cells.append(' '*col_widths[len(cells)])
                    lines.append('| ' + ' | '.join(cells) + ' |')
                    if ri == 0: lines.append('| ' + ' | '.join('-'*w for w in col_widths) + ' |')
                self.text_parts.append('\n' + '\n'.join(lines) + '\n')
        elif tag == 'tr':
            if self.table_row is not None: self.table_rows.append(self.table_row)
            self.table_row = []

    def handle_data(self, data):
        if not self.in_content or self.skip_depth > 0: return
        if self.in_table and self.table_row is not None:
            text = data.strip()
            if text:
                if self.table_row and not self.table_row[-1]: self.table_row[-1] = text
                else: self.table_row.append(text)
            return
        if self.in_pre: self.text_parts.append(data)
        else:
            text = data
            if not self.in_code: text = re.sub(r'\s+', ' ', text)
            self.text_parts.append(text)

    def get_text(self):
        text = ''.join(self.text_parts)
        text = re.sub(r'\n{4,}', '\n\n\n', text)
        text = re.sub(r' +\n', '\n', text)
        return text.strip() + '\n'

html_dir, out_dir = sys.argv[1], sys.argv[2]
os.makedirs(out_dir, exist_ok=True)
count = 0
for f in sorted(os.listdir(html_dir)):
    if not f.endswith('.html'): continue
    try:
        p = MDBookExtractor()
        p.feed(open(os.path.join(html_dir, f)).read())
        open(os.path.join(out_dir, f[:-5]+'.md'), 'w').write(p.get_text())
        count += 1
    except Exception as e:
        print(f"WARN: {f}: {e}", file=sys.stderr)
print(f"Converted {count} pages to {out_dir}")
PYEOF

echo "Done. Updated $(date -Iseconds)"
