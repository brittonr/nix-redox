#!/usr/bin/env python3
"""Serve a built browser site with isolation, prefix and immutable-cache semantics."""
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit


def immutable_path(path):
    return (re.search(r"/assets/[a-f0-9]{64}/", path) is not None
            or path.startswith("/revisions/")) and not path.endswith("/coi-serviceworker.js")


class SiteHandler(SimpleHTTPRequestHandler):
    extensions_map = {**SimpleHTTPRequestHandler.extensions_map,
                      ".wasm": "application/wasm", ".js": "text/javascript",
                      ".mjs": "text/javascript", ".json": "application/json",
                      ".gz": "application/gzip"}

    def __init__(self, *args, prefix="/", isolation=True, **kwargs):
        self.prefix = "/" + prefix.strip("/") + "/" if prefix.strip("/") else "/"
        self.isolation = isolation
        super().__init__(*args, **kwargs)

    def do_GET(self):
        if not self._strip_prefix():
            return
        super().do_GET()

    def do_HEAD(self):
        if not self._strip_prefix():
            return
        super().do_HEAD()

    def _strip_prefix(self):
        parsed = urlsplit(self.path)
        if parsed.path == self.prefix.rstrip("/") and self.prefix != "/":
            self.send_response(308)
            self.send_header("Location", self.prefix)
            self.end_headers()
            return False
        if not parsed.path.startswith(self.prefix):
            self.send_error(404, "Outside configured deployment prefix")
            return False
        relative = unquote(parsed.path[len(self.prefix):])
        if "\x00" in relative or any(part == ".." for part in relative.split("/")):
            self.send_error(400, "Unsafe path is forbidden")
            return False
        if not parsed.path.endswith("/") and (Path(self.directory) / relative).is_dir():
            self.send_response(308)
            self.send_header("Location", parsed.path + "/" + ("?" + parsed.query if parsed.query else ""))
            self.end_headers()
            return False
        self.path = "/" + parsed.path[len(self.prefix):]
        if parsed.query:
            self.path += "?" + parsed.query
        return True

    def send_head(self):
        if not immutable_path(urlsplit(self.path).path):
            # Nix normalizes timestamps: Last-Modified cannot identify a channel
            # revision. Never answer 304 for mutable entrypoints or pointers.
            for header in ("If-Modified-Since", "If-None-Match"):
                if header in self.headers:
                    del self.headers[header]
        return super().send_head()

    def send_response(self, code, message=None):
        self.response_code = code
        super().send_response(code, message)

    def end_headers(self):
        if self.isolation:
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("X-Content-Type-Options", "nosniff")
        path = urlsplit(self.path).path
        immutable = immutable_path(path)
        policy = "public, max-age=31536000, immutable" if immutable else "no-store"
        self.send_header("Cache-Control", "no-store" if self.response_code >= 400 else policy)
        super().end_headers()


def server(root, host="127.0.0.1", port=8000, prefix="/", isolation=True):
    root = Path(root).resolve(strict=True)
    handler = partial(SiteHandler, directory=str(root), prefix=prefix, isolation=isolation)
    return ThreadingHTTPServer((host, port), handler)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("root")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8000)
    p.add_argument("--prefix", default="/")
    p.add_argument("--no-isolation", action="store_true", help="negative-test endpoint, not a supported deployment")
    args = p.parse_args()
    with server(args.root, args.host, args.port, args.prefix, not args.no_isolation) as http:
        print(f"Serving {Path(args.root).resolve()} at http://{args.host}:{http.server_port}/{args.prefix.strip('/')}".rstrip("/") + "/", flush=True)
        http.serve_forever()


if __name__ == "__main__":
    main()
