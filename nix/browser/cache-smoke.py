#!/usr/bin/env python3
"""Real deployed-site Chromium → serial → Redox fd closure proof and fault gate."""
import argparse
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import secrets
import shlex
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urljoin

from manifest import canonical, release_identity, runtime_identity
from serve import server
from smoke import Harness, READY, require, successful

FD = "/nix/var/snix/profiles/default/bin/fd"
PROFILE = "/nix/var/snix/profiles/default/manifest.json"
CACHE = "/nix/var/snix/browser-cache"
STATUS = "#cache-ui output"


def identity(data):
    return {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}


def lines(text):
    return text.replace("\r", "").splitlines()


def nix_file_hash(data):
    # Reuse the exporter's encoding rather than inventing a second narinfo form.
    spec = importlib.util.spec_from_file_location("cache_export", Path(__file__).resolve().parent.parent / "lib/build-binary-cache.py")
    exporter = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(exporter)
    return "sha256:" + exporter.nixbase32_encode(hashlib.sha256(data).digest())


class CacheProof:
    def __init__(self, harness):
        self.h = harness
        self.manifest = None
        self.manifest_url = None
        self.descriptor = None
        self.descriptor_url = None
        self.closure = None
        self.files = {}
        self.routes = []
        self.requests = []
        self.h.page.on("request", lambda request: self.requests.append({"url": request.url, "method": request.method}))
        self.cors_http = None
        self.failed_requests = []
        self.h.page.on("requestfailed", lambda request: self.failed_requests.append({"url": request.url, "failure": request.failure}))
        self.held = []
        self.h.evidence.update(kind="browser-cache-transport", transfers=[], faults=[])

    def fetch(self, url):
        response = self.h.context.request.get(url, timeout=self.h.args.command_timeout * 1000)
        require(response.ok, f"required deployed cache object unavailable: {url} ({response.status})")
        return response.body()

    def inventory(self):
        h = self.h
        self.manifest = copy.deepcopy(h.evidence["manifest"])
        self.manifest_url = h.page.evaluate("window.redoxDemo.manifestURL")
        pin = self.manifest.get("cacheTransport")
        require(pin, "deployable site has no pinned browser cache transport")
        self.descriptor_url = urljoin(self.manifest_url, pin["url"])
        raw = self.fetch(self.descriptor_url)
        require(identity(raw) == {k: pin[k] for k in ("sha256", "size")}, "catalog differs from release pin")
        self.descriptor = json.loads(raw)
        require(self.descriptor.get("target") == "x86_64-unknown-redox", "catalog is not Redox")
        require("fd" in self.descriptor["packages"], "release must curate fd; no substitute package is permitted")
        for file in self.descriptor["packages"]["fd"]["files"]:
            data = self.fetch(urljoin(self.descriptor_url, file["path"]))
            require(identity(data) == {k: file[k] for k in ("sha256", "size")}, f"bad deployed object: {file['path']}")
            self.files[file["path"]] = data
        self.closure = json.loads(self.files["closure.json"])
        self.root = self.descriptor["packages"]["fd"]["storePath"]
        require(self.closure["roots"]["fd"] == self.root, "catalog/closure fd root mismatch")
        seen, pending = set(), [self.root]
        while pending:
            path = pending.pop()
            if path not in seen:
                seen.add(path)
                pending.extend(self.closure["paths"][path]["references"])
        self.paths = sorted(seen)
        self.payload = self.closure["paths"][self.root]["url"]
        self.first_payload = next(file["path"] for file in self.descriptor["packages"]["fd"]["files"]
                                  if file["path"].startswith("nar/"))
        out = Path(h.args.output)
        (out / "transport.raw.json").write_bytes(raw)
        (out / "closure.raw.json").write_bytes(self.files["closure.json"])
        h.evidence["catalog"] = {"url": self.descriptor_url, **pin, "package": "fd", "storePath": self.root,
                                 "closurePaths": self.paths, "files": self.descriptor["packages"]["fd"]["files"]}
        expected_files = {"packages.json", "closure.json", "nix-cache-info"}
        for path in seen:
            expected_files.update((path.split("/")[-1].split("-", 1)[0] + ".narinfo", self.closure["paths"][path]["url"]))
        require(set(self.files) == expected_files, "fd transport includes unrelated payloads or omits reached closure files")
        self.expected_objects = {file["sha256"]: file["size"] for file in self.descriptor["packages"]["fd"]["files"]}
        self.expected_objects[pin["sha256"]] = pin["size"]

    def browsing(self):
        payload_urls = {urljoin(self.descriptor_url, file["path"]) for package in self.descriptor["packages"].values()
                        for file in package["files"] if file["path"].startswith("nar/")}
        fetched = [request for request in self.requests if request["url"] in payload_urls]
        require(not fetched, f"catalog browsing fetched package payloads: {fetched}")
        self.h.evidence["catalogBrowsing"] = {"payloadRequests": fetched, "requests": list(self.requests)}

    def storage(self, label):
        browser = self.h.page.evaluate("""async () => {
          const module=await import('./cache-transport.js');
          const cache=await caches.open('snix-verified-cache-v1');
          const objects=[];
          for(const key of await cache.keys()) {
            const response=await cache.match(key), bytes=await response.arrayBuffer();
            const hash=[...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(x=>x.toString(16).padStart(2,'0')).join('');
            if(!key.url.endsWith('/'+hash)) throw Error('Browser cache identity mismatch');
            objects.push({sha256:hash,size:bytes.byteLength});
          }
          return {limits:module.CACHE_LIMITS,objects,totalBytes:objects.reduce((sum,o)=>sum+o.size,0)};
        }""")
        limits = browser["limits"]
        require(browser["totalBytes"] <= limits["transferBytes"] + limits["descriptorBytes"], "browser immutable storage exceeds budget")
        result = self.h.run(f'for p in {CACHE}/objects/*; do printf "%s " "${{p##*/}}"; wc -c < "$p"; done')
        output = lines(successful(result, "measure guest immutable cache objects"))
        guest = {}
        for line in output:
            match = re.fullmatch(r"([a-f0-9]{64})\s+([0-9]+)", line)
            require(match, f"unexpected guest cache measurement: {line}")
            guest[match[1]] = int(match[2])
        require(guest == self.expected_objects, "guest immutable objects differ from selected pinned closure")
        require(sum(guest.values()) <= limits["transferBytes"] + limits["descriptorBytes"], "guest immutable cache exceeds budget")
        record = {"label": label, "browser": browser, "guestObjects": guest, "guestBytes": sum(guest.values()), "guestMeasurement": result}
        self.h.evidence.setdefault("storage", []).append(record)
        return record

    def observe(self):
        self.h.page.evaluate("""() => {
          window.__cacheProofUnsubscribe?.();
          window.__cacheProof = {counts:{},events:[],objects:[]};
          let pending='';
          window.__cacheProofUnsubscribe = window.redoxDemo.subscribe(text => {
            pending += text;
            let end;
            while ((end=pending.indexOf('\\n')) !== -1) {
              const line=pending.slice(0,end).replaceAll('\\r',''); pending=pending.slice(end+1);
              if(!line.startsWith('@@SNIX_CACHE_V1@@')) continue;
              try {
                const value=JSON.parse(line.slice('@@SNIX_CACHE_V1@@'.length));
                const report=window.__cacheProof;
                const now=performance.now();
                report.firstResponseMs ??= now;
                report.lastResponseMs=now;
                if(value.op==='need') {
                  report.activeObject={index:value.detail.index,startedMs:now,receivedBytes:0};
                  report.objects.push(report.activeObject);
                }
                if(value.op==='ok' && report.activeObject) {
                  if(Number.isInteger(value.detail?.offset)) report.activeObject.receivedBytes=value.detail.offset;
                  if(Number.isInteger(value.detail?.size)) {
                    const object=report.activeObject;
                    object.verifiedBytes=value.detail.size;
                    object.elapsedMs=now-object.startedMs;
                    object.bytesPerSecond=object.elapsedMs?object.verifiedBytes*1000/object.elapsedMs:0;
                    delete report.activeObject;
                  }
                }
                if(value.op==='ok') {
                  if(report.lastAckMs) report.maxAckGapMs=Math.max(report.maxAckGapMs||0,now-report.lastAckMs);
                  report.lastAckMs=now;
                }
                report.counts[value.op]=(report.counts[value.op]||0)+1;
                if(['ready','error','installed'].includes(value.op) && report.events.length<64) report.events.push(value);
              } catch {}
            }
            if(pending.length>8192) pending=pending.slice(-8192);
          });
        }""")

    def protocol(self):
        return self.h.page.evaluate("window.__cacheProof")

    def catalog_ready(self):
        self.h.page.wait_for_function("""() => {
          const select=document.querySelector('#cache-ui select');
          const status=document.querySelector('#cache-ui output');
          return select && [...select.options].some(o=>o.value==='fd') && status?.textContent.startsWith('Catalog loaded;');
        }""", timeout=self.h.args.command_timeout * 1000)
        self.h.page.get_by_label("Curated Redox package", exact=True).select_option("fd")

    def clear_download_cache(self):
        self.h.page.evaluate("async () => { await caches.delete('snix-verified-cache-v1'); }")

    def absent(self):
        successful(self.h.run(f"test ! -e {FD} && test ! -e {shlex.quote(self.root)} && ! command -v fd"),
                   "fd must genuinely be absent before transfer")

    def clean_stage(self):
        successful(self.h.run(f"test ! -e {CACHE}/partial || exit 1\n"
                              'for p in /nix/store/.snix-extract-*; do test ! -e "$p" || exit 1; done'),
                   "failed/completed receiver must remove private cache and extraction stages")

    def profile(self):
        return successful(self.h.run(f"if test -f {PROFILE}; then cat {PROFILE}; else printf 'NO_PROFILE\\n'; fi"),
                          "read active profile bytes")

    def control(self):
        # Package installs outlast the generic command bound: three measured browser
        # installs took 97-116 s, so --install-timeout defaults to 240 s (twice the slowest, rounded up).
        successful(self.h.run("/bin/snix install ripgrep --recursive --cache-path /nix/cache",
                              timeout=self.h.args.install_timeout),
                   "install bundled active-profile control")
        successful(self.h.run("/nix/var/snix/profiles/default/bin/rg --fixed-strings --line-regexp "
                              "REDOX_BROWSER_RIPGREP_SAMPLE /etc/browser-demo/sample.txt"), "run active-profile control")
        self.control_roots = successful(self.h.run("snix store roots"), "record control GC root registry")
        return self.profile()

    def profile_unchanged(self, before):
        require(self.profile() == before, "failed transfer changed active profile bytes")
        successful(self.h.run("/nix/var/snix/profiles/default/bin/rg --fixed-strings --line-regexp "
                              "REDOX_BROWSER_RIPGREP_SAMPLE /etc/browser-demo/sample.txt"), "control profile after failure")
        self.absent()
        successful(self.h.run('test ! -e /nix/var/snix/gcroots/profile-fd && '
                              'test -e /nix/var/snix/gcroots/profile-ripgrep'), "failed transfer preserves control GC root and adds no fd root")
        require(successful(self.h.run("snix store roots"), "read GC roots after failed transfer") == self.control_roots,
                "failed transfer changed an unrelated GC root")
        self.clean_stage()
        require("command not found" not in self.h.page.evaluate("window.redoxDemo.transcript"),
                "failed receiver leaked protocol frames into the foreground shell")

    def start_transfer(self):
        self.h.page.get_by_role("button", name="Fetch and install", exact=True).click()

    def settled(self, installed=False):
        prefix = "Installed fd." if installed else "Not completed:"
        self.h.page.wait_for_function("() => { const text=document.querySelector('#cache-ui output')?.textContent || ''; return text.startsWith('Installed ') || text.startsWith('Not completed:'); }",
                                     timeout=self.h.args.transfer_timeout * 1000)
        status = self.h.page.locator(STATUS).inner_text()
        require(status.startswith(prefix), f"unexpected cache transfer outcome: {status}")
        require(self.h.page.locator("#cache-ui").get_attribute("data-reset-required") != "true",
                f"cache receiver requires a VM reset: {status}")
        self.h.page.wait_for_function("document.querySelector('#cache-ui button')?.disabled === false",
                                     timeout=self.h.args.command_timeout * 1000)
        return self.h.page.locator(STATUS).inner_text()

    def retain(self, label):
        self.h.evidence["lastCacheProtocol"] = self.protocol()
        self.h.evidence["lastCacheStatus"] = self.h.page.locator(STATUS).inner_text()
        self.h.evidence["cacheRequests"] = list(self.requests)
        self.h.evidence["cacheFailedRequests"] = list(self.failed_requests)
        self.h.retain(label)
        self.h.page.screenshot(path=str(Path(self.h.args.output) / f"{label}.png"), full_page=True,
                               timeout=self.h.args.command_timeout * 1000)

    def success(self):
        h = self.h
        with h.phase("fd-real-ui-transfer-install-execute"):
            self.catalog_ready()
            self.browsing()
            self.pristine_profile = self.profile()
            self.observe()
            self.absent()
            self.start_transfer()
            self.h.page.wait_for_function("window.__cacheProof.counts.ok > 2 || document.querySelector('#cache-ui output')?.textContent.startsWith('Not completed:')", timeout=h.args.command_timeout * 1000)
            early_status = h.page.locator(STATUS).inner_text()
            require(not early_status.startswith("Not completed:"), f"guest receiver bootstrap failed: {early_status}")
            responsiveness = h.page.evaluate("({state:window.redoxDemo.state,protocol:window.__cacheProof,now:performance.now(),installDisabled:document.querySelector('#cache-ui button').disabled,selectionDisabled:document.querySelector('#cache-ui select').disabled})")
            require(responsiveness["state"] == "ready" and responsiveness["protocol"]["counts"]["ok"] > 2,
                    "guest did not acknowledge bounded transfer chunks while browser remained responsive")
            require(responsiveness["installDisabled"] and responsiveness["selectionDisabled"],
                    "active serial transfer did not enforce one UI transfer owner")
            h.evidence["transferResponsiveness"] = responsiveness
            status = self.settled(installed=True)
            report = self.protocol()
            installed = [event for event in report["events"] if event["op"] == "installed"]
            require(len(installed) == 1 and installed[0]["detail"]["storePath"] == self.root,
                    "UI success lacks exactly one real guest installed response for the pinned fd root")
            require(installed[0]["detail"]["receivedBytes"] == sum(self.expected_objects.values()) and
                    installed[0]["detail"]["reusedBytes"] == 0,
                    "first receiver byte measurements differ from the bounded selected closure")
            for path in self.paths:
                successful(h.run(f"test -e {shlex.quote(path)}"), f"recursive closure member {path}")
            profile = json.loads(self.profile())
            require(profile["packages"]["fd"]["storePath"] == self.root, "profile did not activate the pinned fd root")
            nonce = secrets.token_hex(12)
            directory = f"/tmp/browser-fd-{nonce}"
            first, second = f"needle-{nonce}-a.txt", f"needle-{nonce}-b.txt"
            successful(h.run(f"mkdir -p {directory}/nested && printf 'first-{nonce}\\n' > {directory}/nested/{first} && "
                             f"printf 'second-{nonce}\\n' > {directory}/{second} && printf 'distractor\\n' > {directory}/other.txt"),
                       "create unique fd guest inputs")
            searches = []
            for name, relative in ((first, f"nested/{first}"), (second, second)):
                result = h.run(f"cd {directory} && {FD} --color never --type f --fixed-strings {name} .")
                output = lines(successful(result, "input-specific installed fd search"))
                require(len(output) == 1 and output[0].removeprefix("./") == relative,
                        f"installed fd returned stale/wrong input result: {output}, expected {relative}")
                searches.append({"needle": name, "expected": relative, **result})
            self.clean_stage()
            self.storage("fd-first-install")
            h.resources("fd-cache-first-install")
            require(report["counts"].get("ok", 0) > 2, "real guest did not acknowledge transferred chunks")
            h.evidence["transfers"].append({"status": status, "protocol": report, "guestInputDirectory": directory,
                                             "searches": searches, "activeProfile": profile})
            self.retain("fd-installed")
        with h.phase("fd-verified-guest-reuse"):
            self.observe()
            before_requests = len(self.requests)
            self.start_transfer()
            reused_status = self.settled(installed=True)
            reused = self.protocol()
            detail = next(event["detail"] for event in reused["events"] if event["op"] == "installed")
            require(reused["counts"].get("have") == len(self.descriptor["packages"]["fd"]["files"]) + 1,
                    "repeat install did not reuse every independently verified guest object")
            require(detail["receivedBytes"] == 0 and detail["reusedBytes"] == sum(self.expected_objects.values()),
                    "repeat install transferred bytes instead of reusing verified immutable guest data")
            # Blob-backed worker creation does not download cache data.
            network_requests = [request for request in self.requests[before_requests:]
                                if request["url"].startswith(("http://", "https://"))]
            require(not network_requests, f"guest cache reuse unexpectedly made network requests: {network_requests}")
            self.h.evidence["guestReuse"] = {"status": reused_status, "protocol": reused,
                                             "requests": self.requests[before_requests:], "networkRequests": network_requests}
            self.storage("fd-guest-reuse")
            successful(h.run(f"{FD} --version"), "execute fd after verified guest reuse")
            self.retain("fd-guest-reuse")
        with h.phase("fd-reset-removes-package-cache-and-inputs"):
            previous = h.page.evaluate("window.redoxDemo.sessionId")
            h.call("reset")
            h.page.wait_for_function("window.redoxDemo.state === 'ready'", timeout=h.args.boot_timeout * 1000)
            current = h.page.evaluate("window.redoxDemo.sessionId")
            require(current != previous, "reset reused old VM session identity")
            require(READY in lines(h.page.evaluate("window.redoxDemo.transcript")), "reset guest readiness absent")
            self.observe()
            self.catalog_ready()
            self.absent()
            successful(h.run(f"test ! -e {directory} && test ! -e {CACHE}"), "reset removes guest files and cache objects/staging")
            require(self.profile() == self.pristine_profile, "reset did not restore the immutable initial profile")
            h.evidence["reset"] = {"oldSession": previous, "newSession": current, "removedDirectory": directory,
                                     "profile": self.profile()}
            self.retain("fd-reset")
        with h.phase("fd-verified-browser-reuse-after-reset"):
            self.observe()
            before_requests = len(self.requests)
            self.start_transfer()
            status = self.settled(installed=True)
            report = self.protocol()
            require(report["counts"].get("need") == len(self.descriptor["packages"]["fd"]["files"]) + 1,
                    "reset guest did not request its absent cache objects")
            network_requests = [request for request in self.requests[before_requests:]
                                if request["url"].startswith(("http://", "https://"))]
            require(not network_requests, f"verified browser reuse after reset made network requests: {network_requests}")
            require(any(event["op"] == "installed" for event in report["events"]), "browser reuse never installed in replacement guest")
            successful(h.run(f"{FD} --version"), "execute fd installed from verified browser cache")
            self.storage("fd-browser-reuse")
            h.evidence["browserReuse"] = {"status": status, "protocol": report,
                                           "requests": self.requests[before_requests:], "networkRequests": network_requests}
            self.retain("fd-browser-reuse")

    def transitive(self):
        candidates = []
        for name, package in self.descriptor["packages"].items():
            if name == "fd":
                continue
            reached, pending = set(), [package["storePath"]]
            while pending:
                path = pending.pop()
                if path not in reached:
                    reached.add(path)
                    pending.extend(self.closure["paths"][path]["references"])
            if len(reached) >= 3:
                candidates.append((name, package, reached))
        require(len(candidates) == 1, "release must curate one distinct download-only executable A -> B -> C runtime fixture")
        name, package, reached = candidates[0]
        self.runtime_name, self.runtime_package, self.runtime_paths = name, package, reached
        self.runtime_files = {}
        for file in package["files"]:
            data = self.fetch(urljoin(self.descriptor_url, file["path"]))
            require(identity(data) == {key: file[key] for key in ("sha256", "size")}, "runtime object differs from pinned inventory")
            self.runtime_files[file["path"]] = data
        h = self.h
        with h.phase("cache-real-transitive-runtime-install-execute"):
            self.fresh()
            for path in reached:
                successful(h.run(f"test ! -e {shlex.quote(path)}"), "download-only runtime closure must be absent from seed")
            self.absent()
            before = self.control()
            before_requests = len(self.requests)
            h.page.get_by_label("Curated Redox package", exact=True).select_option(name)
            self.start_transfer()
            h.page.wait_for_function("name => { const text=document.querySelector('#cache-ui output')?.textContent || ''; return text.startsWith('Installed '+name+'.') || text.startsWith('Not completed:'); }",
                                     arg=name, timeout=h.args.transfer_timeout * 1000)
            status = h.page.locator(STATUS).inner_text()
            require(status.startswith(f"Installed {name}."), f"runtime closure install failed: {status}")
            report = self.protocol()
            installed = [event for event in report["events"] if event["op"] == "installed"]
            require(len(installed) == 1 and installed[0]["detail"]["storePath"] == package["storePath"],
                    "runtime fixture lacks actual correlated guest install acknowledgement")
            for path in reached:
                successful(h.run(f"test -e {shlex.quote(path)}"), "delivered recursive runtime member")
            result = h.run(shlex.quote(package["storePath"] + "/bin/cache-closure-fixture"))
            require(lines(successful(result, "execute real A -> B -> C runtime consumer")) == ["CACHE_CLOSURE_RUNTIME_OK"],
                    "runtime executable did not read the delivered B -> C data")
            profile = json.loads(self.profile())
            require(profile["packages"][name]["storePath"] == package["storePath"], "runtime profile activated wrong root")
            require(profile["packages"]["ripgrep"] == json.loads(before)["packages"]["ripgrep"], "runtime activation changed unrelated profile root")
            self.absent()
            payload_urls = {urljoin(self.descriptor_url, file["path"]) for file in package["files"] if file["path"].startswith("nar/")}
            downloaded = {request["url"] for request in self.requests[before_requests:] if "/nar/" in request["url"]}
            require(downloaded == payload_urls, "runtime selection downloaded unrelated or incomplete package payloads")
            expected = {file["sha256"]: file["size"] for file in package["files"]}
            expected[self.manifest["cacheTransport"]["sha256"]] = self.manifest["cacheTransport"]["size"]
            previous = self.expected_objects
            self.expected_objects = expected
            try:
                measurement = self.storage("transitive-runtime")
            finally:
                self.expected_objects = previous
            self.clean_stage()
            h.resources("transitive-runtime-cache-install")
            h.evidence["transitiveRuntime"] = {"package": name, "paths": sorted(reached), "status": status,
                                               "protocol": report, "execution": result, "downloadedPayloads": sorted(downloaded),
                                               "storage": measurement, "profile": profile}
            self.retain("transitive-runtime")

    def route(self, url, body, status=200, content_type="application/octet-stream"):
        def respond(route):
            route.fulfill(status=status, body=body, content_type=content_type,
                          headers={"Cache-Control": "no-store", "Cross-Origin-Resource-Policy": "same-origin",
                                   "Content-Length": str(len(body))})
        self.h.page.route(url, respond)
        self.routes.append(url)

    def deployment(self, kind):
        """Re-pin every changed layer; do not let an outer hash mask guest faults."""
        descriptor = copy.deepcopy(self.descriptor)
        descriptor["packages"] = {"fd": descriptor["packages"]["fd"]}
        files = dict(self.files)
        closure = copy.deepcopy(self.closure)
        root_info = self.root.split("/")[-1].split("-", 1)[0] + ".narinfo"
        if kind in ("corrupt-nar", "truncated-nar"):
            original = files[self.payload]
            require(len(original) > 8, "root NAR payload too short for corruption/truncation")
            files[self.payload] = bytes([original[0] ^ 255]) + original[1:] if kind == "corrupt-nar" else original[:len(original) // 2]
            body = files[self.payload]
            closure["paths"][self.root]["fileSize"] = len(body)
            info = files[root_info].decode()
            info, count = re.subn(r"(?m)^FileSize: .*", f"FileSize: {len(body)}", info)
            require(count == 1, "root narinfo has no unique FileSize")
            info, count = re.subn(r"(?m)^FileHash: .*", "FileHash: " + nix_file_hash(body), info)
            require(count == 1, "root narinfo has no unique FileHash")
            files[root_info] = info.encode()
            index = json.loads(files["packages.json"])
            index["packages"]["fd"]["fileSize"] = len(body)
            files["packages.json"] = canonical(index) + b"\n"
            files["closure.json"] = canonical(closure) + b"\n"
        elif kind == "wrong-target":
            # Transport and VM remain Redox; real guest closure preflight must
            # reject a declared Linux native root, not the browser catalog guard.
            closure["paths"][self.root]["compatibility"]["target"] = "x86_64-linux"
            files["closure.json"] = canonical(closure) + b"\n"
        elif kind == "missing-dependency":
            descriptor["packages"][self.runtime_name] = copy.deepcopy(self.runtime_package)
            files.update(self.runtime_files)
            dependency = self.closure["paths"][self.runtime_package["storePath"]]["references"][0]
            del closure["paths"][dependency]
            files["closure.json"] = canonical(closure) + b"\n"
        elif kind == "missing-payload":
            # Descriptor is valid but intentionally lacks the root payload;
            # guest preflight must discover the missing closure object.
            for package in descriptor["packages"].values():
                package["files"] = [file for file in package["files"] if file["path"] != self.payload]
            files.pop(self.payload)
        for package in descriptor["packages"].values():
            for file in package["files"]:
                if file["path"] in files:
                    file.update(identity(files[file["path"]]))
        descriptor_raw = canonical(descriptor) + b"\n"
        altered = copy.deepcopy(self.manifest)
        fault_base = urljoin(self.h.base, f"__cache_fault/{kind}/")
        if kind == "cors-http":
            payload = self.payload
            class Handler(BaseHTTPRequestHandler):
                def do_GET(handler):
                    name = handler.path.removeprefix("/")
                    data = descriptor_raw if name == "transport.json" else files.get(name)
                    handler.send_response(200 if data is not None else 404)
                    if name != payload:
                        handler.send_header("Access-Control-Allow-Origin", "*")
                    handler.send_header("Content-Length", str(len(data or b"")))
                    handler.end_headers()
                    handler.wfile.write(data or b"")
            self.cors_http = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            threading.Thread(target=self.cors_http.serve_forever, daemon=True).start()
            fault_base = f"http://127.0.0.1:{self.cors_http.server_port}/"
        altered["cacheTransport"] = {"url": urljoin(fault_base, "transport.json"), **identity(descriptor_raw)}
        inventory = {name: identity(data) for name, data in files.items()}
        inventory["transport.json"] = identity(descriptor_raw)
        altered["cacheIdentity"] = {"sha256": hashlib.sha256(canonical(inventory)).hexdigest(), "files": inventory}
        altered["runtimeRevision"] = runtime_identity(altered)
        altered["revision"] = release_identity(altered)
        manifest_url = urljoin(self.h.base, f"revisions/{altered['revision']}/manifest.json")
        raw = canonical(altered) + b"\n"
        self.route(manifest_url, raw, content_type="application/json")
        if kind != "cors-http":
            self.route(urljoin(fault_base, "transport.json"), descriptor_raw, content_type="application/json")
            for name, data in files.items():
                status = 200
                if name == self.payload:
                    if kind == "corrupt-http":
                        data = bytes([data[0] ^ 255]) + data[1:]
                    elif kind == "truncated-http":
                        data = data[:len(data) // 2]
                    elif kind == "missing-http":
                        data, status = b"deliberately missing cache payload", 404
                self.route(urljoin(fault_base, name), data, status=status)
        out = Path(self.h.args.output)
        (out / f"manifest-{kind}.raw.json").write_bytes(raw)
        (out / f"transport-{kind}.raw.json").write_bytes(descriptor_raw)
        (out / f"closure-{kind}.raw.json").write_bytes(files["closure.json"])
        return manifest_url, altered

    def fresh(self, boot=True):
        h = self.h
        h.call("stop")
        self.release_held()
        for url in self.routes:
            h.page.unroute(url)
        self.routes.clear()
        if self.cors_http is not None:
            self.cors_http.shutdown()
            self.cors_http.server_close()
            self.cors_http = None
        h.open()
        self.clear_download_cache()
        if boot:
            h.boot()
            self.catalog_ready()
            self.observe()

    def fault(self, kind):
        h = self.h
        with h.phase(f"cache-negative-{kind}"):
            self.fresh(boot=False)
            manifest_url, altered = self.deployment(kind)
            h.call("boot", {"mode": "cold", "coldFallback": False, "manifestUrl": manifest_url,
                            "bootTimeoutMs": h.args.boot_timeout * 1000})
            h.page.wait_for_function("window.redoxDemo.state === 'ready'", timeout=h.args.boot_timeout * 1000)
            require(READY in lines(h.page.evaluate("window.redoxDemo.transcript")), "fault guest did not boot")
            require(h.page.evaluate("window.redoxDemo.manifest.revision") == altered["revision"], "fault manifest was not loaded")
            self.catalog_ready()
            self.observe()
            self.absent()
            before = self.control()
            if kind == "missing-dependency":
                for path in self.runtime_paths:
                    successful(h.run(f"test ! -e {shlex.quote(path)}"), "missing-dependency fixture must not be seeded")
                h.page.get_by_label("Curated Redox package", exact=True).select_option(self.runtime_name)
            self.start_transfer()
            status = self.settled()
            protocol = self.protocol()
            require(protocol["counts"].get("ready") == 1, "fault never reached real guest receive worker")
            require(not protocol["counts"].get("installed"), "failed transfer emitted installed acknowledgement")
            errors = [event["detail"]["message"] for event in protocol["events"] if event["op"] == "error"]
            require(errors, "fault has no actual guest receiver failure response")
            if kind in ("corrupt-nar", "truncated-nar"):
                require(any("cannot restore closure member" in error for error in errors),
                        f"fault did not reach real NAR restore/decompression: {errors}")
            elif kind == "wrong-target":
                require(any("wrong-target/unproven closure dependency" in error for error in errors),
                        f"wrong target failed before guest compatibility preflight: {errors}")
            elif kind == "missing-payload":
                require(any("NAR absent from pinned inventory" in error for error in errors),
                        f"missing payload failed before guest closure preflight: {errors}")
            elif kind == "missing-dependency":
                require(any("missing closure dependency" in error for error in errors),
                        f"missing dependency failed before guest graph traversal: {errors}")
            else:
                expected = {"corrupt-http": "Short/corrupt cache object", "truncated-http": "Cache length mismatch",
                            "missing-http": "Cache Fetch failed (404)", "cors-http": "Failed to fetch"}[kind]
                require(expected in status, f"HTTP fault did not exercise intended fetch failure: {status}")
            if kind == "cors-http":
                failed = [request for request in self.failed_requests if request["url"].endswith(self.payload)]
                require(failed, "CORS failure lacks actual failed cross-origin payload request")
                messages = [entry["text"] for entry in h.evidence["console"] if "CORS" in entry["text"] and self.payload in entry["text"]]
                require(messages, "cross-origin request failure lacks Chromium's actual CORS policy diagnostic")
                h.evidence["corsFailure"] = {"requests": failed, "console": list(h.evidence["console"])}
            self.profile_unchanged(before)
            if kind == "missing-dependency":
                successful(h.run(f"test ! -e {shlex.quote(self.runtime_package['storePath'])} && "
                                 f"test ! -e /nix/var/snix/gcroots/profile-{self.runtime_name}"),
                           "missing runtime dependency must not publish root or activation")
            h.evidence["faults"].append({"kind": kind, "manifestRevision": altered["revision"],
                                          "sessionId": h.page.evaluate("window.redoxDemo.sessionId"),
                                          "manifestEvidence": f"manifest-{kind}.raw.json",
                                          "status": status, "protocol": protocol, "profileBefore": before,
                                          "profilePreserved": True, "stagingRemoved": True})
            h.evidence["faults"][-1]["rootsPreserved"] = self.control_roots
            self.retain(f"negative-{kind}")

    def hold_payload(self):
        url = urljoin(self.descriptor_url, self.first_payload)
        def hold(route):
            self.held.append(route)
        self.h.page.route(url, hold)
        self.routes.append(url)
        return url

    def release_held(self):
        outcomes = []
        for route in self.held:
            try:
                route.fulfill(status=200, body=self.files[self.first_payload],
                              headers={"Cross-Origin-Resource-Policy": "same-origin"})
                outcomes.append("late HTTP body delivered")
            except Exception as error:
                # Chromium may already have aborted the real request. Both
                # outcomes must be followed by the same guest/DOM assertions.
                outcomes.append(str(error))
        self.held.clear()
        return outcomes

    def lifecycle_fault(self, kind):
        h = self.h
        with h.phase(f"cache-negative-{kind}"):
            self.fresh()
            self.absent()
            before = self.control()
            self.hold_payload()
            old_session = h.page.evaluate("window.redoxDemo.sessionId")
            with h.page.expect_request(urljoin(self.descriptor_url, self.first_payload),
                                       timeout=h.args.transfer_timeout * 1000):
                self.start_transfer()
            h.page.wait_for_function("window.__cacheProof.counts.need > 0", timeout=h.args.command_timeout * 1000)
            require(self.held, "no actual pending payload HTTP request to cancel/interrupt")
            if kind == "cancel":
                h.page.get_by_role("button", name="Cancel transfer", exact=True).click()
                status = self.settled()
                late = self.release_held()
                report = self.protocol()
                require(any(event["op"] == "error" and "cancelled" in event["detail"].get("message", "")
                            for event in report["events"]), "UI cancellation never reached real guest cancel frame")
                require(not report["counts"].get("installed"), "cancelled transfer installed a package")
                require(h.page.evaluate("window.redoxDemo.sessionId") == old_session, "cancel unexpectedly replaced the VM")
                self.profile_unchanged(before)
            else:
                self.retain(f"{kind}-in-flight")
                if kind == "interruption":
                    h.call("stop")
                    diagnostic = h.call("diagnostics")
                    require(h.page.evaluate("window.redoxDemo.state") == "stopped" and
                            diagnostic["resources"]["trackedFrames"] == 0, "interrupted guest resources survived stop")
                    late = self.release_held()
                    h.boot()
                else:
                    # Reset while a real payload fetch/receiver is pending, then
                    # deliberately deliver its late HTTP response to the old owner.
                    h.call("reset")
                    h.page.wait_for_function("window.redoxDemo.state === 'ready'", timeout=h.args.boot_timeout * 1000)
                    late = self.release_held()
                self.catalog_ready()
                current = h.page.evaluate("window.redoxDemo.sessionId")
                require(current != old_session, "interruption/reset reused guest generation")
                self.observe()
                h.page.wait_for_timeout(h.args.quiescence_ms)
                status = h.page.locator(STATUS).inner_text()
                require(status.startswith("Catalog loaded;"), f"stale callback changed replacement UI: {status}")
                self.absent()
                successful(h.run(f"test ! -e {CACHE}"), "old transfer data/staging survived replacement guest")
                require(self.profile() == self.pristine_profile, "old transfer/control profile leaked into replacement guest")
                nonce = secrets.randbelow(10**8)
                result = h.call("executeExpression", f"{nonce} + 17")
                require(str(nonce + 17) in lines(successful(result, "new generation after stale transfer callback")),
                        "replacement guest responded with stale output")
                report = self.protocol()
                require(not report["counts"].get("installed"), "stale transfer activated replacement profile")
            h.evidence["faults"].append({"kind": kind, "oldSession": old_session,
                                          "newSession": h.page.evaluate("window.redoxDemo.sessionId"),
                                          "lateHTTP": late, "status": status, "protocol": report,
                                          "profileSemantics": "preserved" if kind == "cancel" else "reset-to-immutable-initial",
                                          "stagingRemoved": True})
            self.retain(f"negative-{kind}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("site", help="built deployable browser-site tree, including pinned fd cache")
    parser.add_argument("--chromium", required=True, help="real Chromium executable")
    parser.add_argument("--output", default="browser-cache-evidence")
    parser.add_argument("--prefix", default="/redox-preview/")
    parser.add_argument("--boot-timeout", type=int, default=600)
    parser.add_argument("--command-timeout", type=int, default=120)
    parser.add_argument("--install-timeout", type=int, default=240, help="measured bound for the bundled control-package install")
    parser.add_argument("--transfer-timeout", type=int, default=3600, help="bound for a full serial closure transfer")
    parser.add_argument("--quiescence-ms", type=int, default=1000)
    parser.add_argument("--no-sandbox", action="store_true", help="only for a disposable runner without Chromium sandbox support")
    args = parser.parse_args()
    require(all(value > 0 for value in (args.boot_timeout, args.command_timeout, args.install_timeout, args.transfer_timeout, args.quiescence_ms)),
            "all execution deadlines and quiescence must be positive")
    from playwright.sync_api import sync_playwright
    with server(args.site, port=0, prefix=args.prefix) as http:
        threading.Thread(target=http.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{http.server_port}/{args.prefix.strip('/')}/"
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(executable_path=args.chromium, headless=True,
                                                  args=["--no-sandbox"] if args.no_sandbox else [])
            h = Harness(args, browser, base)
            proof = CacheProof(h)
            try:
                h.open()
                proof.clear_download_cache()
                h.boot()
                proof.inventory()
                h.retain("booted-before-cache")
                proof.success()
                proof.transitive()
                for kind in ("corrupt-http", "truncated-http", "missing-http", "cors-http", "corrupt-nar", "truncated-nar",
                             "wrong-target", "missing-payload", "missing-dependency"):
                    proof.fault(kind)
                for kind in ("cancel", "interruption", "stale-reset"):
                    proof.lifecycle_fault(kind)
                h.evidence["success"] = True
            except Exception as error:
                h.evidence["failure"] = str(error)
                raise
            finally:
                try:
                    try:
                        h.evidence["lastCacheProtocol"] = proof.protocol()
                        h.evidence["lastCacheStatus"] = h.page.evaluate("document.querySelector('#cache-ui output')?.textContent || ''")
                        h.evidence["cacheRequests"] = list(proof.requests)
                        h.evidence["cacheFailedRequests"] = list(proof.failed_requests)
                    except Exception as error:
                        h.evidence["cacheEvidenceError"] = str(error)
                    h.retain("final")
                    try:
                        h.page.screenshot(path=str(Path(args.output) / "final.png"), full_page=True,
                                          timeout=args.command_timeout * 1000)
                    finally:
                        h.call("stop")
                finally:
                    proof.release_held()
                    if proof.cors_http is not None:
                        proof.cors_http.shutdown()
                        proof.cors_http.server_close()
                    try:
                        h.context.close()
                    finally:
                        try:
                            browser.close()
                        finally:
                            http.shutdown()


if __name__ == "__main__":
    main()
