#!/usr/bin/env python3
"""Focused contract tests; these do not substitute for the real Chromium gate."""
import gzip
import hashlib
import json
import os
import re
import shutil
from urllib.parse import urljoin
from pathlib import Path
import tempfile
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import urlopen

from build_pages_redirect import build_redirect
from manifest import assemble, canonical, parser
from serve import server
from smoke import assert_clock, assert_fixtures, mandatory_ids, successful
from snapshot import safe_artifact_path
from stage_cloudflare_pages import stage as stage_cloudflare_pages


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def file(self, name, data=b"asset"):
        target = self.root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.parent.chmod(target.parent.stat().st_mode | 0o700)
        if target.exists():
            target.chmod(target.stat().st_mode | 0o600)
        target.write_bytes(data)
        return target

    def release(self, revision="a" * 40, corrupt_engine=False, output="out",
                engine_payload=b"asset", frontend=b"<!doctype html><title>contract fixture only</title>",
                landing_payload=b"landing asset remains published", readonly_source=False, ram_mib=1024):
        self.file("site/live/index.html", frontend)
        self.file("site/coi-serviceworker.js", b"// contract fixture")
        self.file("site/assets/landing.svg", landing_payload)
        self.file("engine/out.js", engine_payload)
        self.file("engine/qemu-system-x86_64.wasm", b"\x00asm")
        self.file("engine/qemu-system-x86_64.worker.js")
        self.file("engine/licenses/LICENSE", b"engine license notice")
        self.file("engine/source/source.tar.gz", b"corresponding source bytes")
        names = ("out.js", "qemu-system-x86_64.wasm", "qemu-system-x86_64.worker.js")
        files = {name: {"sha256": hashlib.sha256((self.root / "engine" / name).read_bytes()).hexdigest(),
                        "size": (self.root / "engine" / name).stat().st_size} for name in names}
        self.file("engine/engine-pins.json", json.dumps({"files": files}).encode())
        if corrupt_engine:
            self.file("engine/out.js", b"factory bytes not declared by publisher")
        for name in ("xterm.js", "xterm.css", "xterm-pty.js"):
            self.file("vendor/" + name)
        self.file("vendor/licenses/NOTICE", b"vendor notice")
        self.file("image/boot/BOOTX64.EFI")
        self.file("image/redox.img", b"guest-disk-contract" * 1024)
        self.file("image/fixtures/catalog.json", b'{"tests":["required"]}')
        self.file("firmware/OVMF.fd")
        self.file("firmware/efi-virtio.rom")
        self.file("firmware/kvmvapic.bin")
        self.file("firmware/licenses/NOTICE", b"firmware notice")
        machine = {"ram": f"{ram_mib}M", "ramMiB": ram_mib, "args": ["-nic", "none"], "firmware": {"file": "OVMF.fd"}, "devices": []}
        self.file("machine.json", json.dumps(machine, indent=2).encode())
        self.file("cache/transport.json", b'{"version":1,"packages":{}}')
        self.file("cache/nar/abc.nar.zst")
        args = parser().parse_args(["--out", str(self.root / output), "--site", str(self.root / "site"),
            "--engine", str(self.root / "engine"), "--vendor", str(self.root / "vendor"),
            "--image", str(self.root / "image"), "--machine", str(self.root / "machine.json"),
            "--firmware", str(self.root / "firmware/OVMF.fd"), "--firmware-notices", str(self.root / "firmware"),
            "--cache", str(self.root / "cache"), "--revision", revision])
        if readonly_source:
            for directory in ("site", "engine", "vendor", "image", "firmware", "cache"):
                source = self.root / directory
                for path in [source, *source.rglob("*")]:
                    path.chmod(0o555 if path.is_dir() else 0o444)
        assemble(args)
        return self.root / output, machine

    def test_complete_revision_pointer_and_transfer_identities(self):
        root, machine = self.release()
        pointer = json.loads((root / "manifest.json").read_bytes())
        self.assertEqual(pointer, json.loads((root / "channel.json").read_bytes()))
        actual = root / pointer["manifest"]["url"]
        raw = actual.read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(), pointer["manifest"]["sha256"])
        self.assertEqual(len(raw), pointer["manifest"]["size"])
        manifest = json.loads(raw)
        self.assertEqual(manifest["machineHash"], hashlib.sha256(canonical(machine)).hexdigest())
        self.assertEqual(manifest["target"], "x86_64-unknown-redox")
        for role in ("engine", "wasm", "worker", "firmware", "disk", "efi", "xterm", "xtermCss", "pty"):
            item = manifest["assets"][role]
            path = (actual.parent / item["url"]).resolve()
            self.assertTrue(path.is_relative_to(root.resolve()))
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), item["sha256"])
            self.assertEqual(path.stat().st_size, item["size"])
        disk = manifest["assets"]["disk"]
        transfer = (actual.parent / disk["url"]).read_bytes()
        decoded = gzip.decompress(transfer)
        self.assertEqual(len(decoded), disk["logicalSize"])
        self.assertEqual(hashlib.sha256(decoded).hexdigest(), disk["rawSha256"])
        self.assertNotEqual(disk["size"], disk["logicalSize"])
        self.assertEqual(set(manifest["firmwareFiles"]), {"OVMF.fd", "efi-virtio.rom", "kvmvapic.bin"})

    def test_same_source_different_bundles_keep_saved_urls_byte_stable(self):
        first, _ = self.release(output="first", engine_payload=b"engine variant one", readonly_source=True)
        first_pointer = json.loads((first / "channel.json").read_bytes())
        first_manifest = json.loads((first / first_pointer["manifest"]["url"]).read_bytes())
        published = self.root / "published"
        shutil.copytree(first, published)
        with server(published, port=0, prefix="/project/") as http:
            threading.Thread(target=http.serve_forever, daemon=True).start()
            base = f"http://127.0.0.1:{http.server_port}/project/"
            def read(relative):
                with urlopen(base + relative) as response:
                    return response.read()
            def selected_files(pointer):
                manifest_url = pointer["manifest"]["url"]
                manifest = json.loads(read(manifest_url))
                engine_url = urljoin(base + manifest_url, manifest["assets"]["engine"]["url"]).removeprefix(base)
                return {manifest_url: read(manifest_url), engine_url: read(engine_url),
                        f"revisions/{manifest['revision']}/live/index.html": read(f"revisions/{manifest['revision']}/live/index.html"),
                        f"revisions/{manifest['revision']}/assets/landing.svg": read(f"revisions/{manifest['revision']}/assets/landing.svg")}
            def publish(output):
                # Upload immutable objects/revisions before switching either pointer.
                for namespace in ("assets", "revisions"):
                    for entry in (output / namespace).iterdir():
                        target = published / namespace / entry.name
                        if not target.exists():
                            shutil.copytree(entry, target)
                for pointer in ("channel.json", "manifest.json"):
                    shutil.copyfile(output / pointer, published / pointer)
            try:
                saved_first = selected_files(first_pointer)
                second, _ = self.release(output="second", engine_payload=b"engine variant two", readonly_source=True)
                second_pointer = json.loads((second / "channel.json").read_bytes())
                second_manifest = json.loads((second / second_pointer["manifest"]["url"]).read_bytes())
                self.assertEqual(first_manifest["sourceRevision"], second_manifest["sourceRevision"])
                self.assertNotEqual(first_pointer["revision"], second_pointer["revision"])
                self.assertNotEqual(first_manifest["runtimeRevision"], second_manifest["runtimeRevision"])
                publish(second)
                self.assertEqual(json.loads(read("channel.json"))["revision"], second_manifest["revision"])
                for url, content in saved_first.items():
                    self.assertEqual(read(url), content)
                saved_second = selected_files(second_pointer)
                third, _ = self.release(output="third", engine_payload=b"engine variant two",
                                        frontend=b"<!doctype html><title>changed frontend</title>",
                                        landing_payload=b"changed frontend asset", readonly_source=True)
                third_pointer = json.loads((third / "channel.json").read_bytes())
                third_manifest = json.loads((third / third_pointer["manifest"]["url"]).read_bytes())
                self.assertEqual(second_manifest["runtimeRevision"], third_manifest["runtimeRevision"])
                self.assertNotEqual(second_pointer["revision"], third_pointer["revision"])
                publish(third)
                self.assertEqual(json.loads(read("channel.json"))["revision"], third_manifest["revision"])
                self.assertEqual(read(f"revisions/{third_manifest['revision']}/assets/landing.svg"), b"changed frontend asset")
                for url, content in {**saved_first, **saved_second}.items():
                    self.assertEqual(read(url), content)
            finally:
                http.shutdown()

    def test_unrepresentable_engine_ram_fails_before_publication(self):
        with self.assertRaises(ValueError):
            self.release(ram_mib=2048)
        self.assertFalse((self.root / "out/channel.json").exists())

    def test_publisher_engine_identity_rejects_changed_payload_before_publication(self):
        with self.assertRaises(ValueError):
            self.release(corrupt_engine=True)
        self.assertFalse((self.root / "out/channel.json").exists())

    def test_missing_required_asset_is_fatal(self):
        root, _ = self.release()
        (self.root / "engine/qemu-system-x86_64.wasm").unlink()
        args = parser().parse_args(["--out", str(self.root / "broken"), "--site", str(self.root / "site"),
            "--engine", str(self.root / "engine"), "--vendor", str(self.root / "vendor"), "--image", str(self.root / "image"),
            "--machine", str(self.root / "machine.json"), "--firmware", str(self.root / "firmware/OVMF.fd"), "--revision", "broken"])
        with self.assertRaises(ValueError):
            assemble(args)
        self.assertFalse((self.root / "broken/channel.json").exists())

    def test_prefix_headers_mime_cache_and_no_gzip_decoding(self):
        root, _ = self.release()
        pointer = json.loads((root / "channel.json").read_bytes())
        manifest_path = root / pointer["manifest"]["url"]
        manifest = json.loads(manifest_path.read_bytes())
        with server(root, port=0, prefix="/project/") as http:
            threading.Thread(target=http.serve_forever, daemon=True).start()
            self.addCleanup(http.shutdown)
            base = f"http://127.0.0.1:{http.server_port}"
            with urlopen(base + "/project/channel.json") as response:
                self.assertEqual(response.headers["Cross-Origin-Opener-Policy"], "same-origin")
                self.assertEqual(response.headers["Cross-Origin-Embedder-Policy"], "require-corp")
                self.assertEqual(response.headers["Cross-Origin-Resource-Policy"], "same-origin")
            for role, mime in (("wasm", "application/wasm"), ("disk", "application/gzip")):
                path = (manifest_path.parent / manifest["assets"][role]["url"]).resolve().relative_to(root.resolve())
                with urlopen(base + "/project/" + path.as_posix()) as response:
                    self.assertEqual(response.headers.get_content_type(), mime)
                    self.assertIn("immutable", response.headers["Cache-Control"])
                    self.assertIsNone(response.headers.get("Content-Encoding"))
            for path in ("/channel.json", "/project/revisions/unavailable/manifest.json", "/project/%2e%2e/channel.json"):
                with self.assertRaises(HTTPError):
                    urlopen(base + path)
            http.shutdown()

    def test_directory_redirect_retains_deployment_prefix(self):
        self.file("redirect/live/index.html", b"prefix redirect contract")
        with server(self.root / "redirect", port=0, prefix="/project/") as http:
            threading.Thread(target=http.serve_forever, daemon=True).start()
            try:
                base = f"http://127.0.0.1:{http.server_port}"
                with urlopen(base + "/project/live") as response:
                    self.assertEqual(response.url, base + "/project/live/")
                    self.assertEqual(response.read(), b"prefix redirect contract")
            finally:
                http.shutdown()

    def test_no_isolation_is_observable_not_claimed(self):
        self.file("headers/index.html")
        with server(self.root / "headers", port=0, isolation=False) as http:
            threading.Thread(target=http.serve_forever, daemon=True).start()
            self.addCleanup(http.shutdown)
            with urlopen(f"http://127.0.0.1:{http.server_port}/") as response:
                self.assertIsNone(response.headers.get("Cross-Origin-Opener-Policy"))
                self.assertIsNone(response.headers.get("Cross-Origin-Embedder-Policy"))
            http.shutdown()

    def test_mandatory_fixture_assertions_reject_skip_missing_duplicate(self):
        catalog = {"tests": ["required"]}
        good = "FUNC_TESTS_START\nFUNC_TEST:required:PASS\nFUNC_TESTS_COMPLETE\n"
        self.assertEqual(assert_fixtures(good, catalog), {"required": ["PASS"]})
        for broken in (good.replace(":PASS", ":SKIP"), good.replace(":PASS", ":FAIL"),
                       good.replace("FUNC_TEST:required:PASS\n", ""), good + "FUNC_TEST:required:PASS\n",
                       good.replace("FUNC_TESTS_COMPLETE", "")):
            with self.assertRaises(AssertionError):
                assert_fixtures(broken, catalog)
        with self.assertRaises(AssertionError):
            mandatory_ids({"tests": []})
        with self.assertRaises(AssertionError):
            successful({"status": 127, "output": "Snix missing"}, "Snix")

    def test_external_clock_detects_proportional_skew(self):
        self.assertEqual(assert_clock(4, 4, .35), 1)
        for elapsed in (1, 16):
            with self.assertRaises(AssertionError):
                assert_clock(elapsed, 4, .35)

    def test_snapshot_artifact_paths_allow_nested_files_and_reject_url_or_traversal_syntax(self):
        for path in ("OVMF.fd", "firmware-pack/QEMU,cgthree.bin", "sub.dir/file_name-1.bin"):
            self.assertTrue(safe_artifact_path(path), path)
        for path in ("", ".", "..", "./file", "dir/../file", "dir//file", "/file",
                     "C:/file", "https://host/file", "file?query", "file#fragment",
                     "file%2fsecret", r"dir\file", "café/file"):
            self.assertFalse(safe_artifact_path(path), path)

    def test_root_deployment_and_headers_generation(self):
        site_dir = Path(os.environ.get("REDOX_SITE_DIR", Path(__file__).resolve().parents[2] / "site"))
        self.file("site/_headers", (site_dir / "_headers").read_bytes())
        root, _ = self.release()
        headers_text = (root / "_headers").read_text(encoding="utf-8")
        # Built _headers must use Cloudflare Pages ! Cache-Control detaches and valid patterns.
        self.assertIn("Cross-Origin-Opener-Policy: same-origin", headers_text)
        self.assertIn("Cross-Origin-Embedder-Policy: require-corp", headers_text)
        self.assertIn("Cross-Origin-Resource-Policy: same-origin", headers_text)
        self.assertIn("/revisions/:revision/coi-serviceworker.js", headers_text)
        self.assertNotIn("/*.wasm", headers_text)
        self.assertNotIn("/revisions/*/coi-serviceworker.js", headers_text)
        # Every asset hash directory rule must detach Cache-Control before overriding it.
        asset_rules = re.findall(r"/assets/[a-f0-9]{64}/\*\n  ! Cache-Control\n  Cache-Control: public, max-age=31536000, immutable", headers_text)
        self.assertGreaterEqual(len(asset_rules), 1)
        # Root serving (prefix="/") must work alongside --prefix tests.
        pointer = json.loads((root / "channel.json").read_bytes())
        with server(root, port=0, prefix="/") as http:
            threading.Thread(target=http.serve_forever, daemon=True).start()
            self.addCleanup(http.shutdown)
            base = f"http://127.0.0.1:{http.server_port}"
            with urlopen(base + "/channel.json") as response:
                self.assertEqual(response.headers["Cross-Origin-Opener-Policy"], "same-origin")
                self.assertEqual(response.headers["Cross-Origin-Embedder-Policy"], "require-corp")
                self.assertEqual(response.headers["Cross-Origin-Resource-Policy"], "same-origin")
                self.assertEqual(response.headers["Cache-Control"], "no-store")
                self.assertEqual(json.loads(response.read())["revision"], pointer["revision"])
            with urlopen(base + "/live/") as response:
                self.assertEqual(response.headers["Cache-Control"], "no-store")
                self.assertIn(b"channel.json", response.read())
            with urlopen(base + f"/revisions/{pointer['revision']}/live/") as response:
                self.assertIn("immutable", response.headers["Cache-Control"])
            http.shutdown()

    def test_repo_site_canonical_urls_point_to_nixredox_com(self):
        site_dir = Path(os.environ.get("REDOX_SITE_DIR", Path(__file__).resolve().parents[2] / "site"))
        index_html = (site_dir / "index.html").read_text(encoding="utf-8")
        live_html = (site_dir / "live/index.html").read_text(encoding="utf-8")
        self.assertIn('<link rel="canonical" href="https://nixredox.com/">', index_html)
        self.assertIn('<meta property="og:url" content="https://nixredox.com/">', index_html)
        self.assertIn('<meta property="og:image" content="https://nixredox.com/assets/orbital-social.png">', index_html)
        self.assertNotIn("brittonr.github.io/nix-redox", index_html)
        self.assertIn('<link rel="canonical" href="https://nixredox.com/live/">', live_html)
        self.assertNotIn("brittonr.github.io/nix-redox", live_html)

    def test_cloudflare_pages_staging_splits_only_oversized_files(self):
        root, _ = self.release()
        small_out = self.root / "cf-small"
        small_summary = stage_cloudflare_pages(root, small_out, max_file_bytes=25 * 1024 * 1024)
        self.assertEqual(small_summary["overflowCount"], 0)
        self.assertFalse((small_out / "pages/_worker.js").exists())
        self.assertFalse((small_out / "pages/_routes.json").exists())
        self.assertTrue((small_out / "pages/channel.json").is_file())

        # Trigger overflow with a small threshold so gzipped disk goes to R2 overflow.
        split_out = self.root / "cf-split"
        pointer = json.loads((root / "channel.json").read_bytes())
        manifest = json.loads((root / pointer["manifest"]["url"]).read_bytes())
        disk_rel = manifest["assets"]["disk"]["url"].removeprefix("../../")
        disk_size = manifest["assets"]["disk"]["size"]
        split_summary = stage_cloudflare_pages(root, split_out, max_file_bytes=max(1, disk_size - 1))
        self.assertGreaterEqual(split_summary["overflowCount"], 1)
        overflow_keys = {item["key"] for item in split_summary["overflowFiles"]}
        self.assertIn(disk_rel, overflow_keys)
        self.assertFalse((split_out / "pages" / disk_rel).exists())
        self.assertTrue((split_out / "r2-overflow" / disk_rel).is_file())
        self.assertEqual((split_out / "r2-overflow" / disk_rel).read_bytes(), (root / disk_rel).read_bytes())
        routes = json.loads((split_out / "pages/_routes.json").read_text(encoding="utf-8"))
        self.assertEqual(routes["version"], 1)
        self.assertIn("/" + disk_rel, routes["include"])
        worker = (split_out / "pages/_worker.js").read_text(encoding="utf-8")
        self.assertIn("SITE_OVERFLOW", worker)
        self.assertIn("Cross-Origin-Opener-Policy", worker)
        self.assertIn("Cross-Origin-Embedder-Policy", worker)
        self.assertEqual(split_summary["pagesFiles"] + split_summary["overflowCount"], split_summary["totalFiles"])

    def test_github_pages_redirect_artifact_contract(self):
        redir = build_redirect(self.root / "gh-redirect", target="https://nixredox.com/", prefix="/nix-redox/")
        self.assertTrue((redir / ".nojekyll").is_file())
        index_html = (redir / "index.html").read_text(encoding="utf-8")
        live_html = (redir / "live/index.html").read_text(encoding="utf-8")
        notfound_html = (redir / "404.html").read_text(encoding="utf-8")
        self.assertIn('content="0; url=https://nixredox.com/"', index_html)
        self.assertIn('<link rel="canonical" href="https://nixredox.com/">', index_html)
        self.assertIn('content="0; url=https://nixredox.com/live/"', live_html)
        self.assertIn('<link rel="canonical" href="https://nixredox.com/live/">', live_html)
        self.assertIn('var prefix = "/nix-redox/";', notfound_html)
        self.assertIn('target.origin !== expectedOrigin', notfound_html)
        with self.assertRaises(ValueError):
            build_redirect(self.root / "bad-redirect", target="http://nixredox.com/")


if __name__ == "__main__":
    unittest.main()
