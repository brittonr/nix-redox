#!/usr/bin/env python3
"""Generate a clean static GitHub Pages redirect site pointing to the canonical domain."""
import argparse
import html
import json
from pathlib import Path
from urllib.parse import urlsplit


def normalize_target(url):
    parsed = urlsplit(url)
    if parsed.scheme != "https" or not parsed.netloc:
        raise ValueError(f"canonical target must be an https:// origin URL, got: {url!r}")
    path = parsed.path or "/"
    if not path.endswith("/"):
        path += "/"
    return f"https://{parsed.netloc}{path}", f"https://{parsed.netloc}"


def render_exact_redirect(destination, title):
    escaped = html.escape(destination, quote=True)
    js_dest = json.dumps(destination)
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html.escape(title)}</title>
  <link rel="canonical" href="{escaped}">
  <meta http-equiv="refresh" content="0; url={escaped}">
  <script>
    (function () {{
      var target = new URL({js_dest});
      target.search = window.location.search;
      target.hash = window.location.hash;
      window.location.replace(target.href);
    }})();
  </script>
</head>
<body>
  <main>
    <h1>Moved to <a href="{escaped}">{escaped}</a></h1>
    <p>nix-redox has moved to its canonical cross-origin-isolated host. Continue to <a href="{escaped}">{escaped}</a>.</p>
  </main>
</body>
</html>
"""


def render_404_redirect(target_root, target_origin, prefix):
    escaped_root = html.escape(target_root, quote=True)
    clean_prefix = "/" + prefix.strip("/") + "/" if prefix.strip("/") else "/"
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Redirecting to {html.escape(target_root)}</title>
  <link rel="canonical" href="{escaped_root}">
  <meta http-equiv="refresh" content="0; url={escaped_root}">
  <script>
    (function () {{
      var root = {json.dumps(target_root)};
      var expectedOrigin = {json.dumps(target_origin)};
      var prefix = {json.dumps(clean_prefix)};
      var pathname = window.location.pathname || "/";
      var rest = pathname.startsWith(prefix) ? pathname.slice(prefix.length) : pathname;
      rest = rest.replace(/^\\/+/, "");
      var target = new URL(rest, root);
      if (target.origin !== expectedOrigin) {{
        target = new URL(root);
      }}
      target.search = window.location.search;
      target.hash = window.location.hash;
      window.location.replace(target.href);
    }})();
  </script>
</head>
<body>
  <main>
    <h1>Moved to <a href="{escaped_root}">{escaped_root}</a></h1>
    <p>nix-redox has moved to its canonical cross-origin-isolated host. Continue to <a href="{escaped_root}">{escaped_root}</a>.</p>
  </main>
</body>
</html>
"""


def build_redirect(out_dir, target="https://nixredox.com/", prefix="/nix-redox/"):
    target_root, target_origin = normalize_target(target)
    out = Path(out_dir)
    if out.exists() and any(out.iterdir()):
        raise ValueError(f"redirect output directory must be empty: {out}")
    out.mkdir(parents=True, exist_ok=True)
    (out / ".nojekyll").write_text("", encoding="utf-8")
    (out / "index.html").write_text(
        render_exact_redirect(target_root, f"Redirecting to {target_root}"),
        encoding="utf-8",
    )
    live_dir = out / "live"
    live_dir.mkdir(parents=True, exist_ok=True)
    live_target = target_root + "live/"
    (live_dir / "index.html").write_text(
        render_exact_redirect(live_target, f"Redirecting to {live_target}"),
        encoding="utf-8",
    )
    (out / "404.html").write_text(
        render_404_redirect(target_root, target_origin, prefix),
        encoding="utf-8",
    )
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("out", help="empty output directory for GitHub Pages redirect site")
    p.add_argument("--target", default="https://nixredox.com/", help="canonical HTTPS origin URL")
    p.add_argument("--prefix", default="/nix-redox/", help="legacy GitHub Pages path prefix to strip")
    args = p.parse_args()
    build_redirect(args.out, args.target, args.prefix)


if __name__ == "__main__":
    main()
