#!/usr/bin/env python3
"""Real Chromium/guest integration gate; writes evidence even when the guest fails."""
import argparse
from contextlib import contextmanager
import gzip
import hashlib
import json
from pathlib import Path
import re
import secrets
import threading
import time
from urllib.parse import urljoin, urlsplit

from serve import server
from manifest import canonical, release_identity, runtime_identity

READY = "REDOX_BROWSER_DEMO_READY:v1:shell=1:snix=1:initial=1"
BASH = "/nix/system/profile/bin/bash"
# Chromium terminates a removed document's dedicated workers asynchronously.
# On Chromium 148 that took about 2 s on both the v3 and fixed-engine releases.
WORKER_TEARDOWN_SECONDS = 10


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def mandatory_ids(catalog):
    if isinstance(catalog, dict) and "tests" in catalog:
        values = catalog["tests"]
    elif isinstance(catalog, dict) and "mandatory" in catalog:
        values = catalog["mandatory"]
    elif isinstance(catalog, dict) and "fixtures" in catalog:
        values = [item["id"] for item in catalog["fixtures"] if item.get("mandatory", True)]
    else:
        raise AssertionError("fixture catalog has no mandatory fixture identity list")
    require(isinstance(values, list) and values and all(isinstance(x, str) for x in values), "mandatory fixture catalog is empty or malformed")
    require(len(values) == len(set(values)), "duplicate mandatory fixture identities")
    return values


def assert_fixtures(output, catalog):
    lines = output.replace("\r", "").splitlines()
    require(lines.count(catalog.get("suiteStart", "FUNC_TESTS_START")) == 1, "fixture suite start missing or duplicated")
    require(lines.count(catalog.get("suiteComplete", "FUNC_TESTS_COMPLETE")) == 1, "fixture suite completion missing or duplicated")
    results = {}
    for line in output.replace("\r", "").splitlines():
        match = re.fullmatch(r"FUNC_TEST:([^:]+):(PASS|FAIL|SKIP)(?::.*)?", line)
        if match:
            results.setdefault(match[1], []).append(match[2])
    for name in mandatory_ids(catalog):
        require(results.get(name) == ["PASS"], f"mandatory fixture {name}: expected exactly one PASS, got {results.get(name)}")
    require(not any(status in ("FAIL", "SKIP") for statuses in results.values() for status in statuses), "fixture emitted FAIL or SKIP")
    return results


def assert_clock(elapsed, requested, tolerance):
    ratio = elapsed / requested
    require(1 - tolerance <= ratio <= 1 + tolerance,
            f"external clock skew: guest sleep {requested}s took {elapsed:.3f}s host monotonic (ratio {ratio:.3f})")
    return ratio


def successful(result, label):
    require(isinstance(result, dict) and result.get("status") == 0, f"{label} failed: {result}")
    return result.get("output", "")


class Harness:
    def __init__(self, args, browser, base):
        self.args, self.browser, self.base = args, browser, base
        self.context = browser.new_context(service_workers="allow")
        # Chromium's native Ctrl+V path needs clipboard permission in the
        # isolated headless context; writing text alone does not grant reads.
        origin = urlsplit(base)
        self.context.grant_permissions(["clipboard-read", "clipboard-write"],
                                       origin=f"{origin.scheme}://{origin.netloc}")
        self.page = self.context.new_page()
        self.page.set_default_timeout(args.boot_timeout * 1000)
        self.started = time.monotonic()
        self.download_state = "cold-download"
        self.cdp = browser.new_browser_cdp_session()
        self.evidence = {"schemaVersion": 1, "kind": "browser", "mode": "cold", "success": False,
                         "browser": browser.version, "args": vars(args), "phases": [],
                         "console": [], "errors": [], "sessions": [], "negative": []}
        self.page.on("console", lambda msg: self.evidence["console"].append({"type": msg.type, "text": msg.text}))
        self.page.on("pageerror", lambda error: self.evidence["errors"].append(str(error)))

    @contextmanager
    def phase(self, name):
        start = time.monotonic()
        record = {"name": name, "startedMonotonic": start, "cacheCondition": self.download_state}
        record["processMemoryBefore"] = self.process_memory()
        self.evidence["phases"].append(record)
        try:
            yield record
            key = None
            if name in ("cold-boot", "snapshot-boot"):
                key = "readinessMs"
            elif name.endswith("-first-command"):
                key = "firstCommandMs"
            elif name.endswith("-mandatory-fixtures") or name == "graphical-mandatory-demo":
                key = "mandatoryFixturesMs"
            if key:
                observed = record["readinessMs"] if key == "readinessMs" else (time.monotonic() - start) * 1000
                ceiling = self.resource_limits()[key]
                record["performanceBudget"] = {"metric": key, "observed": observed, "ceiling": ceiling}
                require(observed <= ceiling, f"{name} exceeds measured Redox {key} ceiling: {observed} > {ceiling}")
            record["success"] = True
        except Exception as error:
            record["success"] = False
            record["error"] = str(error)
            raise
        finally:
            record["processMemoryAfter"] = self.process_memory()
            record["elapsedMs"] = (time.monotonic() - start) * 1000

    def call(self, method, argument=None):
        bound = (self.args.boot_timeout if method in ("boot", "reset") else self.args.command_timeout) * 1000
        return self.page.evaluate("async ([name,arg,bound]) => { const api=window.redoxDemo; if(!api) throw Error('redoxDemo API unavailable'); let timer; try { return await Promise.race([arg===null ? api[name]() : api[name](arg),new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error(name+' harness deadline exceeded')),bound)})]); } finally {clearTimeout(timer);} }", [method, argument, bound])

    def run(self, command, timeout=None):
        return self.page.evaluate("async ([command, timeoutMs]) => { let timer; try { return await Promise.race([window.redoxDemo.run(command,{timeoutMs}),new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('command harness deadline exceeded')),timeoutMs+1000)})]); } finally {clearTimeout(timer);} }", [command, (timeout or self.args.command_timeout) * 1000])

    def open(self, url=None):
        self.page.goto(url or urljoin(self.base, "live/"), wait_until="domcontentloaded")
        self.page.wait_for_function("!!window.redoxDemo")

    def direct_preflight(self):
        selected = self.page.evaluate("async () => {const url=new URL('../manifest.json',location.href);const response=await fetch(url,{cache:'no-store'});if(!response.ok)throw Error('Immutable manifest unavailable');return await response.json();}")
        actual_url = urljoin(self.page.url, "../manifest.json")
        raw = self.context.request.get(actual_url).body()
        require(json.loads(raw) == selected, "preboot immutable manifest changed between browser and evidence fetch")
        self.evidence.update(manifest=selected, revision=selected["revision"], sourceRevision=selected["sourceRevision"],
                             runtimeRevision=selected["runtimeRevision"], assets=selected["assets"],
                             machineHash=selected["machineHash"], firmwareFiles=selected.get("firmwareFiles", {}),
                             manifestHash=hashlib.sha256(raw).hexdigest())
        output = Path(self.args.output)
        output.mkdir(parents=True, exist_ok=True)
        (output / "manifest.raw.json").write_bytes(raw)
        self.evaluator_present = bool(selected.get("evaluator"))
        if not self.evaluator_present:
            self.evidence["directEvaluator"] = {"available": False, "reason": "No evaluator package in this immutable manifest"}
            return
        with self.phase("direct-evaluator-before-boot"):
            require(self.page.evaluate("window.redoxDemo.state") == "stopped", "direct evaluator preflight unexpectedly needs an active VM")
            result = self.page.evaluate("""async descriptor => {
              const identities=[];
              for(const [name,asset] of Object.entries(descriptor.artifacts)) {
                const response=await fetch(new URL('../playground/'+name,location.href),{cache:'no-store'});
                if(!response.ok) throw Error('Evaluator artifact unavailable: '+name);
                const bytes=await response.arrayBuffer();
                const hash=[...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(x=>x.toString(16).padStart(2,'0')).join('');
                if(bytes.byteLength!==asset.size || hash!==asset.sha256)throw Error('Evaluator artifact identity mismatch: '+name);
                identities.push({name,sha256:hash,size:bytes.byteLength});
              }
              const {exerciseDirectEvaluator}=await import(new URL('../playground/exercise.js',location.href));
              let timer;
              try {return {identities,exercise:await Promise.race([exerciseDirectEvaluator(),new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('Direct evaluator exercise deadline exceeded')),120000)})])};}
              finally {clearTimeout(timer);}
            }""", selected["evaluator"])
            require(self.page.evaluate("window.redoxDemo.state") == "stopped", "standalone evaluator started the guest")
            self.evidence["directEvaluator"] = {"available": True, "metadata": selected["evaluator"]["metadata"], "beforeBoot": result}

    def direct_guest_comparison(self, mode):
        if not self.evaluator_present:
            return
        with self.phase(f"{mode}-direct-vs-guest-and-cancellation"):
            before = self.page.evaluate("window.redoxDemo.sessionId")
            report = self.page.evaluate("""async () => {
              const {comparePortableFixtures,exerciseDirectEvaluator}=await import(new URL('../playground/exercise.js',location.href));
              let timer;
              try {return await Promise.race([(async()=>({comparison:await comparePortableFixtures(async source=>{const result=await window.redoxDemo.executeExpression(source);return {exitCode:result.status,stdout:result.output};}), cancellationWhileVMReady:await exerciseDirectEvaluator()}))(),new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('Direct/guest comparison deadline exceeded')),240000)})]);}
              finally {clearTimeout(timer);}
            }""")
            require(self.page.evaluate("window.redoxDemo.sessionId") == before and self.page.evaluate("window.redoxDemo.state") == "ready", "direct cancellation disrupted active guest lifecycle")
            nonce = secrets.randbelow(100000000) + 1
            result = self.call("executeExpression", f"{nonce} * 3 + 5")
            require(str(nonce * 3 + 5) in successful(result, "guest after direct cancellation").replace("\r", "").splitlines(), "direct worker cancellation left guest stale or unresponsive")
            self.evidence["directEvaluator"].setdefault("withGuest", []).append({"mode": mode, "sessionId": before, "report": report, "nonce": nonce, "guestAfterCancellation": result})

    def boot(self, mode="cold", manifest_url=None, *, disk_backend="preload"):
        with self.phase(f"{mode}-boot") as record:
            self.call("boot", {"mode": mode, "diskBackend": disk_backend, "coldFallback": False, "bootTimeoutMs": self.args.boot_timeout * 1000, **({"manifestUrl": manifest_url} if manifest_url else {})})
            self.page.wait_for_function("window.redoxDemo.state === 'ready'", timeout=self.args.boot_timeout * 1000)
            transcript = self.page.evaluate("window.redoxDemo.transcript")
            record["readinessMs"] = (time.monotonic() - record["startedMonotonic"]) * 1000
            self.download_state = "warm-cache"
            self.evidence["manifest"] = self.page.evaluate("window.redoxDemo.manifest")
            self.evidence["revision"] = self.evidence["manifest"]["revision"]
            self.evidence["sourceRevision"] = self.evidence["manifest"]["sourceRevision"]
            self.evidence["runtimeRevision"] = self.evidence["manifest"]["runtimeRevision"]
            self.evidence["machineHash"] = self.evidence["manifest"]["machineHash"]
            self.evidence["assets"] = self.evidence["manifest"]["assets"]
            self.evidence["firmwareFiles"] = self.evidence["manifest"].get("firmwareFiles", {})
            self.evidence["readyMarker"] = READY
            actual_url = urljoin(self.base, f"revisions/{self.evidence['revision']}/manifest.json")
            raw = self.context.request.get(actual_url).body()
            self.evidence["manifestHash"] = hashlib.sha256(raw).hexdigest()
            output = Path(self.args.output); output.mkdir(parents=True, exist_ok=True)
            (output / "manifest.raw.json").write_bytes(raw)
            marker = READY
            if mode == "snapshot":
                descriptor = self.evidence["manifest"]["snapshot"]
                metadata_raw = self.context.request.get(urljoin(actual_url, descriptor["url"])).body()
                require(len(metadata_raw) == descriptor["size"] and hashlib.sha256(metadata_raw).hexdigest() == descriptor["sha256"], "snapshot proof metadata identity mismatch")
                metadata = json.loads(metadata_raw)
                marker = metadata["handshake"]["resumedMarker"]
                require(isinstance(marker, str) and marker, "snapshot resume marker missing")
                (output / "snapshot.raw.json").write_bytes(metadata_raw)
            require(marker in transcript.replace("\r", "").splitlines(), f"exact {mode} readiness marker missing from raw serial")
            self.evidence.setdefault("readinessRuns", []).append({"mode": mode, "marker": marker, "readinessMs": record["readinessMs"]})
            with self.phase(f"{mode}-first-command"):
                basic = self.call("executeExpression", "1 + 1")
                require("2" in successful(basic, "basic cold proof").replace("\r", "").splitlines(), "basic Snix proof missing")
                self.evidence["snix"] = {"expression": "1 + 1", "expected": "2", **basic}
            session = self.page.evaluate("window.redoxDemo.sessionId")
            require(session and session not in self.evidence["sessions"], "boot reused an old session identity")
            self.evidence["sessions"].append(session)

    def correctness(self, mode):
        nonce = secrets.randbelow(10**8) + 1
        expression = f"let n = {nonce}; in n * 7 + 13"
        with self.phase(f"{mode}-nonce-eval"):
            result = self.call("executeExpression", expression)
            output = successful(result, "active guest nonce evaluation")
            require(str(nonce * 7 + 13) in output.replace("\r", "").splitlines(), "nonce-derived Snix result absent")
            self.evidence.setdefault("snixRuns", []).append({"expression": expression, "expected": nonce * 7 + 13, **result})
        with self.phase(f"{mode}-mandatory-fixtures"):
            output = successful(self.run(f"{BASH} /etc/browser-demo/run.sh all", self.args.fixture_timeout), "mandatory fixtures")
            self.evidence.setdefault("fixtureRuns", []).append(assert_fixtures(output, self.evidence["manifest"]["fixtures"]))
        with self.phase(f"{mode}-nonce-build"):
            paths = []
            for selected in (str(nonce), str(nonce + 1)):
                result = self.run(f"{BASH} /etc/browser-demo/run.sh build {selected}", self.args.fixture_timeout)
                output = successful(result, "fresh nonce guest build")
                matches = re.findall(r"^REDOX_BROWSER_DEMO_BUILD:" + re.escape(selected) + r":(/nix/store/[^\r\n ]+)$", output.replace("\r", ""), re.M)
                require(len(matches) == 1, "fresh nonce build store identity absent or duplicated")
                path = matches[0]
                content = successful(self.run(f"cat {path}"), "read actual fresh guest output")
                require(content.replace("\r", "") == selected + "\n", "fresh build bytes differ from selected input plus newline")
                paths.append(path)
                self.evidence.setdefault("buildRuns", []).append({"nonce": selected, "storePath": path, "bytes": content, **result})
            require(paths[0] != paths[1], "different build inputs reused old output path")
        with self.phase(f"{mode}-host-clock") as record:
            # Warm both executable startup and the nonzero nanosleep path. A
            # shell builtin omits the sleep binary's substantial WASM startup.
            successful(self.run("/bin/sleep 0"), "clock executable warmup")
            successful(self.run("/bin/sleep 1"), "clock timer warmup")
            start = time.monotonic()
            successful(self.run("/bin/sleep 0"), "same-executable clock control")
            overhead = time.monotonic() - start
            start = time.monotonic()
            successful(self.run(f"/bin/sleep {self.args.sleep_seconds}"), "guest sleep")
            elapsed = time.monotonic() - start
            record.update(hostElapsedSeconds=elapsed, commandOverheadSeconds=overhead,
                          adjustedHostElapsedSeconds=max(0, elapsed-overhead),
                          requestedSeconds=self.args.sleep_seconds)
            record["ratio"] = assert_clock(record["adjustedHostElapsedSeconds"], self.args.sleep_seconds, self.args.clock_tolerance)
            # Repeat a real baseline-length guest sleep, but assert the 4x
            # duration a fast-clock fault would have skipped. A one-second
            # sleep is too close to variable WASM startup and serial overhead.
            injected_seconds = self.args.sleep_seconds
            expected_seconds = injected_seconds * 4
            start = time.monotonic()
            successful(self.run(f"/bin/sleep {injected_seconds}"), "injected fast-clock sleep")
            injected_raw = time.monotonic() - start
            injected = max(0, injected_raw - overhead)
            fault = {"factor": 4, "requestedSeconds": expected_seconds,
                     "injectedSeconds": injected_seconds, "rawHostElapsedSeconds": injected_raw,
                     "hostElapsedSeconds": injected}
            record["injectedClockFault"] = fault
            try:
                assert_clock(injected, expected_seconds, self.args.clock_tolerance)
            except AssertionError as error:
                fault["detected"] = str(error)
            else:
                raise AssertionError("external sleep assertion failed to detect 4x proportional clock fault")

    def process_memory(self):
        """Sample CDP-enumerated OS processes; never call JS heap total VM RAM."""
        try:
            processes = self.cdp.send("SystemInfo.getProcessInfo")["processInfo"]
        except Exception as error:
            return {"available": False, "reason": f"CDP process enumeration unavailable: {error}"}
        samples, unavailable = [], []
        for process in processes:
            pid = int(process["id"])
            try:
                fields = {}
                for line in Path(f"/proc/{pid}/smaps_rollup").read_text().splitlines():
                    key, _, value = line.partition(":")
                    if key in ("Rss", "Pss"):
                        fields[key] = int(value.split()[0]) * 1024
                if "Rss" not in fields or "Pss" not in fields:
                    raise ValueError("smaps_rollup lacks RSS/PSS")
                samples.append({"pid": pid, "type": process.get("type"), "rssBytes": fields["Rss"], "pssBytes": fields["Pss"]})
            except (OSError, ValueError) as error:
                unavailable.append({"pid": pid, "type": process.get("type"), "reason": str(error)})
        if not samples:
            return {"available": False, "reason": "No CDP-enumerated process exposes readable Linux smaps_rollup", "unavailable": unavailable}
        result = {"available": True, "units": "bytes", "scope": "CDP-enumerated processes of this launched Chromium instance, not guest-only memory",
                  "rssBytes": sum(x["rssBytes"] for x in samples), "pssBytes": sum(x["pssBytes"] for x in samples),
                  "processes": samples, "unavailable": unavailable, "partial": bool(unavailable),
                  "caveat": "Summed RSS double-counts shared pages; PSS apportions shared pages. Samples exclude inaccessible or exited processes. Peak is only the maximum phase/resource sample, not a continuous OS high-water mark."}
        peaks = self.evidence.setdefault("processMemorySampledPeak", {"units": "bytes", "rssBytes": 0, "pssBytes": 0})
        for key in ("rssBytes", "pssBytes"):
            peaks[key] = max(peaks[key], result[key])
        return result

    def resource_limits(self):
        policy = self.evidence["manifest"]["fixtures"]["resources"]
        limits = policy.get("ceilings")
        require(isinstance(limits, dict) and policy.get("baseline"), "Release lacks a measured Redox resource policy")
        for key in ("readinessMs", "firstCommandMs", "mandatoryFixturesMs", "compressedDiskBytes", "logicalDiskBytes",
                    "guestRamMiB", "wasmMemoryBytes", "sampledProcessRssBytes", "sampledProcessPssBytes"):
            require(type(limits.get(key)) is int and limits[key] > 0, f"Invalid measured resource ceiling: {key}")
        self.evidence["resourcePolicy"] = policy
        return limits

    def resources(self, label):
        metrics = self.page.evaluate("""async () => {
          const diagnostic = await window.redoxDemo.diagnostics();
          return {diagnostic,
            jsHeap:performance.memory?{usedJSHeapSize:performance.memory.usedJSHeapSize,totalJSHeapSize:performance.memory.totalJSHeapSize,jsHeapSizeLimit:performance.memory.jsHeapSizeLimit}:null,
            transfer:performance.getEntriesByType('resource').map(x=>({name:x.name,transferSize:x.transferSize,encodedBodySize:x.encodedBodySize,decodedBodySize:x.decodedBodySize,duration:x.duration}))};
        }""")
        metrics["cdpTargets"] = self.cdp.send("Target.getTargets")["targetInfos"]
        metrics["processMemory"] = self.process_memory()
        self.evidence.setdefault("resources", []).append({"label": label, **metrics})
        limits = self.resource_limits()
        manifest = self.evidence["manifest"]
        for key, observed in (("compressedDiskBytes", manifest["assets"]["disk"]["size"]),
                              ("logicalDiskBytes", manifest["guestIdentity"]["logicalSize"]),
                              ("guestRamMiB", manifest["machine"]["ramMiB"])):
            require(observed <= limits[key], f"{label} exceeds measured Redox {key} ceiling: {observed} > {limits[key]}")
        wasm = metrics["diagnostic"]["resources"].get("wasmMemoryBytes")
        if wasm is not None:
            require(0 < wasm <= limits["wasmMemoryBytes"], f"{label} exceeds measured Wasm memory ceiling: {wasm}")
        if metrics["processMemory"]["available"]:
            for metric, key in (("rssBytes", "sampledProcessRssBytes"), ("pssBytes", "sampledProcessPssBytes")):
                observed = metrics["processMemory"][metric]
                require(observed <= limits[key], f"{label} exceeds sampled browser {metric} ceiling: {observed} > {limits[key]}")
        return metrics

    def retain(self, label):
        out = Path(self.args.output)
        out.mkdir(parents=True, exist_ok=True)
        try:
            transcript = self.page.evaluate("window.redoxDemo?.transcript || ''")
            serial_name = f"serial-{len(self.evidence.get('serial', [])):03d}-{label}.log"
            (out / serial_name).write_text(transcript)
            self.evidence.setdefault("serial", []).append(serial_name)
            self.evidence["lastDiagnostics"] = self.call("diagnostics")
        except Exception as error:
            self.evidence["evidenceError"] = str(error)
        self.evidence["elapsedMs"] = (time.monotonic() - self.started) * 1000
        self.evidence["logs"] = self.evidence.get("serial", [])
        (out / "evidence.json").write_text(json.dumps(self.evidence, indent=2, default=str) + "\n")
        if "manifest" in self.evidence:
            (out / "manifest.json").write_text(json.dumps(self.evidence["manifest"], indent=2) + "\n")

    def stopped(self):
        stopped_at = time.monotonic()
        self.call("stop")
        before = self.page.evaluate("({serial:window.redoxDemo.transcript,id:window.redoxDemo.sessionId,state:window.redoxDemo.state})")
        require(before["state"] == "stopped", f"stop did not enter stopped state: {before}")
        self.page.wait_for_timeout(self.args.quiescence_ms)
        after = self.page.evaluate("({serial:window.redoxDemo.transcript,id:window.redoxDemo.sessionId,state:window.redoxDemo.state})")
        require(before == after, "old guest session continued activity after stop")
        while self.engine_workers() and time.monotonic() - stopped_at < WORKER_TEARDOWN_SECONDS:
            self.page.wait_for_timeout(100)
        self.evidence.setdefault("workerTeardownMs", []).append(round((time.monotonic() - stopped_at) * 1000))
        metrics = self.resources("stopped")
        diagnostic = metrics["diagnostic"]["resources"]
        for key in ("trackedFrames", "pendingCommands"):
            require(key in diagnostic and diagnostic[key] == 0, f"stopped lifecycle leaked {key}: {diagnostic}")
        require(0 <= diagnostic["verifiedCacheBytes"] <= diagnostic["cacheLimitBytes"], "verified immutable asset cache exceeded declared bounded capacity")
        workers = self.engine_workers(metrics["cdpTargets"])
        require(not workers, f"old engine worker targets survived document destruction: {workers}")
        try:
            result = self.run("echo OLD_SESSION_MUST_NOT_RUN", timeout=2)
        except Exception:
            result = {"status": "rejected"}
        require(result.get("status") != 0, "stopped guest accepted a command")

    def engine_workers(self, targets=None):
        targets = self.cdp.send("Target.getTargets")["targetInfos"] if targets is None else targets
        return [target for target in targets if target["type"] in ("worker", "shared_worker")
                and "/playground/evaluator-worker.js" not in target.get("url", "")]

    def terminal_input(self, mode):
        editor = self.page.frame_locator("iframe.vm-frame").locator(".xterm-helper-textarea")
        editor.focus()
        require(editor.evaluate("element => document.activeElement === element"), "terminal did not receive keyboard focus")

        def wait_lines(*lines):
            self.page.wait_for_function("expected => {const lines=window.redoxDemo.transcript.replace(/\\r/g,'').split('\\n');return expected.every(line=>lines.includes(line));}",
                                        arg=list(lines), timeout=self.args.command_timeout * 1000)

        with self.phase(f"{mode}-typed-serial-input"):
            nonce = secrets.randbelow(10**8) + 1
            token = secrets.token_hex(12)
            command = f"printf '\\n'; browser_command {token} snix eval --expr '{nonce} * 7 + 13'"
            self.page.keyboard.type(command)
            self.page.keyboard.press("Enter")
            wait_lines(str(nonce * 7 + 13), f"REDOX_BROWSER_DEMO_COMMAND:{token}:0")
            self.evidence.setdefault("terminalRuns", []).append({"mode": mode, "kind": "typed-keys-and-enter", "nonce": nonce, "expected": nonce * 7 + 13, "token": token})

        with self.phase(f"{mode}-multiline-serial-paste"):
            nonce = secrets.randbelow(10**8) + 1
            token = secrets.token_hex(12)
            path = f"/tmp/browser-paste-{token}"
            pasted = (f"printf '%s' '{nonce}' > {path}\r\n"
                      f"printf '\\n'; browser_command {token} snix eval --expr 'builtins.fromJSON (builtins.readFile \"{path}\") * 11 + 7'\r\n")
            self.page.evaluate("text => navigator.clipboard.writeText(text)", pasted)
            editor.focus()
            self.page.keyboard.press("Control+Shift+V")
            wait_lines(str(nonce * 11 + 7), f"REDOX_BROWSER_DEMO_COMMAND:{token}:0")
            self.evidence["terminalRuns"].append({"mode": mode, "kind": "clipboard-multiline-crlf-paste", "nonce": nonce, "expected": nonce * 11 + 7, "path": path, "token": token})

        with self.phase(f"{mode}-serial-interrupt-byte"):
            token = secrets.token_hex(12)
            ready = f"TTY_INTERRUPT_READY:{token}"
            received = f"TTY_INTERRUPT_BYTE:{token}:3"
            command = f"printf '\\n{ready}\\n'; IFS= read -r -n 1 browser_key; printf '\\nTTY_INTERRUPT_BYTE:{token}:%d\\n' \"'$browser_key\""
            editor.focus()
            self.page.keyboard.type(command)
            self.page.keyboard.press("Enter")
            wait_lines(ready)
            self.page.keyboard.press("Control+C")
            wait_lines(received)
            require(self.page.evaluate("window.redoxDemo.state") == "ready", "Ctrl+C terminated the emulator instead of delivering byte 0x03")
            self.evidence["terminalRuns"].append({"mode": mode, "kind": "ctrl-c-guest-byte", "expected": 3, "token": token})

    def exercise(self, mode, *, disk_backend="preload"):
        self.boot(mode, disk_backend=disk_backend)
        self.direct_guest_comparison(mode)
        self.terminal_input(mode)
        self.correctness(mode)
        self.resources(f"{mode}-ready")
        marker = "/tmp/browser-reset-" + secrets.token_hex(8)
        successful(self.run(f"echo retained > {marker} && test -f {marker}"), "reset mutation")
        self.retain(mode)
        for cycle in range(self.args.cycles):
            with self.phase(f"{mode}-reset-{cycle}"):
                old = self.page.evaluate("window.redoxDemo.sessionId")
                self.call("reset")
                self.page.wait_for_function("window.redoxDemo.state === 'ready'", timeout=self.args.boot_timeout * 1000)
                expected_marker = self.evidence["readinessRuns"][-1]["marker"]
                serial = self.page.evaluate("window.redoxDemo.transcript")
                require(expected_marker in serial.replace("\r", "").splitlines(), f"{mode} reset readiness handshake absent")
                new = self.page.evaluate("window.redoxDemo.sessionId")
                require(new != old and new not in self.evidence["sessions"], "reset reused session")
                self.evidence["sessions"].append(new)
                successful(self.run(f"test ! -e {marker}"), "reset must remove guest mutation")
                nonce = secrets.randbelow(1000000)
                output = successful(self.call("executeExpression", f"{nonce} + 1"), "fresh reset guest")
                require(str(nonce + 1) in output.replace("\r", "").splitlines(), "reset responded with stale guest output")
                self.resources(f"{mode}-reset-{cycle}")
                successful(self.run(f"echo retained > {marker}"), "repeat reset mutation")
                self.retain(f"{mode}-reset-{cycle}")
            self.stopped()
            self.boot(mode, disk_backend=disk_backend)
        self.stopped()

    def negative(self):
        manifest = self.evidence["manifest"]
        snapshot_faults = tuple(f"snapshot-{role}" for role in ("engine", "cpu", "ram", "firmware", "disk", "machine")) if manifest.get("snapshot") else ()
        for kind in ("missing-manifest", "missing", "corrupt", "metadata", "engine-exit", "broken-boot") + snapshot_faults:
            with self.phase(f"negative-{kind}"):
                self.open()
                altered = json.loads(json.dumps(manifest))
                if kind == "metadata":
                    altered["machineHash"] = "0" * 64
                elif kind == "engine-exit":
                    invalid_argument = "-redox-smoke-" + secrets.token_hex(8)
                    altered["machine"]["args"].append(invalid_argument)
                    altered["machineHash"] = hashlib.sha256(canonical(altered["machine"])).hexdigest()
                elif kind in ("missing", "corrupt"):
                    altered["assets"]["wasm"]["url"] = urljoin(self.base, f"__fault/{kind}.wasm")
                elif kind == "broken-boot":
                    # A correctly hashed, correctly sized gzip of an empty boot disk:
                    # asset validation succeeds, actual guest boot cannot reach Snix.
                    logical = altered["assets"]["disk"]["logicalSize"]
                    import io
                    buffer = io.BytesIO()
                    with gzip.GzipFile(fileobj=buffer, mode="wb", mtime=0) as zipped:
                        block = bytes(1024 * 1024)
                        remaining = logical
                        while remaining:
                            count = min(remaining, len(block)); zipped.write(block[:count]); remaining -= count
                    broken = buffer.getvalue()
                    altered["assets"].pop("diskChunks", None)
                    altered.pop("diskChunks", None)
                    raw_hash = hashlib.sha256()
                    remaining = logical
                    while remaining:
                        count = min(remaining, len(block)); raw_hash.update(block[:count]); remaining -= count
                    altered["assets"]["disk"] = {"url": urljoin(self.base, "__fault/broken.img.gz"), "sha256": hashlib.sha256(broken).hexdigest(), "size": len(broken), "encoding": "gzip", "logicalSize": logical, "rawSha256": raw_hash.hexdigest()}
                    self.page.route("**/__fault/broken.img.gz", lambda route: route.fulfill(status=200, body=broken, content_type="application/gzip"))
                elif kind.startswith("snapshot-"):
                    descriptor = manifest["snapshot"]
                    metadata_url = urljoin(urljoin(self.page.url, "../manifest.json"), descriptor["url"])
                    metadata_raw = self.context.request.get(metadata_url).body()
                    require(len(metadata_raw) == descriptor["size"] and hashlib.sha256(metadata_raw).hexdigest() == descriptor["sha256"], "snapshot fault requires genuine pinned metadata")
                    snapshot = json.loads(metadata_raw)
                    role = kind.removeprefix("snapshot-")
                    if role in ("cpu", "ram", "machine"):
                        machine = snapshot["machine"]
                        if role == "ram":
                            machine.update(ram="512M", ramMiB=512)
                        else:
                            flag = "-cpu" if role == "cpu" else "-machine"
                            value = "max" if role == "cpu" else "pc-i440fx-8.1"
                            machine[role] = value
                            machine["args"][machine["args"].index(flag) + 1] = value
                        snapshot["machineHash"] = hashlib.sha256(canonical(machine)).hexdigest()
                    else:
                        snapshot["bindings"]["runtimeAssets"][role]["sha256"] = "0" * 64
                    # Valid object/envelope hashes ensure the browser rejects
                    # the incompatible capture, not a corrupt download.
                    snapshot["compatibilityHash"] = hashlib.sha256(canonical(snapshot["bindings"])).hexdigest()
                    metadata_raw = canonical(snapshot)
                    fault_url = urljoin(self.base, f"__fault/{kind}.json")
                    altered["snapshot"] = {"url": fault_url, "sha256": hashlib.sha256(metadata_raw).hexdigest(), "size": len(metadata_raw)}
                    self.page.route(fault_url, lambda route: route.fulfill(status=200, body=metadata_raw, content_type="application/json"))
                self.page.route("**/__fault/missing.wasm", lambda route: route.fulfill(status=404, body="missing"))
                self.page.route("**/__fault/corrupt.wasm", lambda route: route.fulfill(status=200, body=b"corrupt", content_type="application/wasm"))
                altered["runtimeRevision"] = runtime_identity(altered)
                altered["revision"] = release_identity(altered)
                actual_url = urljoin(self.base, f"revisions/{altered['revision']}/manifest.json")
                if kind == "missing-manifest":
                    self.page.route(actual_url, lambda route: route.fulfill(status=404, body="Immutable revision artifacts are unavailable"))
                else:
                    self.page.route(actual_url, lambda route: route.fulfill(status=200, body=json.dumps(altered), content_type="application/json"))
                failure = None
                started = time.monotonic()
                try:
                    # Let the session fail and dispose before the outer bound;
                    # otherwise --boot-timeout < the UI's 300s default races it.
                    self.call("boot", {"mode": "snapshot" if kind.startswith("snapshot-") else "cold", "coldFallback": False,
                                       "manifestUrl": actual_url, "bootTimeoutMs": self.args.boot_timeout * 500})
                    self.page.wait_for_function("window.redoxDemo.state === 'failed' || window.redoxDemo.state === 'ready'", timeout=self.args.boot_timeout * 1000)
                except Exception as error:
                    failure = str(error)
                state = self.page.evaluate("window.redoxDemo.state")
                diagnostic = self.call("diagnostics")
                require(state == "failed", f"{kind} did not fail explicitly: {state}, {failure}")
                require(diagnostic.get("error") and diagnostic.get("phase"), f"{kind} failure omitted explicit error/phase diagnostics")
                if kind == "engine-exit":
                    require(invalid_argument in self.page.evaluate("window.redoxDemo.transcript"), "real emulator did not reject the injected CLI argument")
                    require(time.monotonic() - started < 30, "emulator exit waited for the guest boot deadline instead of failing promptly")
                if kind != "broken-boot":
                    require(READY not in self.page.evaluate("window.redoxDemo.transcript"), f"{kind} launched a guest before validating assets")
                    require(diagnostic["resources"]["trackedFrames"] == 0, f"{kind} created an engine document before validating inputs")
                self.evidence["negative"].append({"kind": kind, "state": state, "error": failure, "diagnostics": diagnostic})
                self.retain(f"negative-{kind}")
                self.call("stop")
                self.page.unroute_all(behavior="wait")
        # The outer transport decoder must not be hidden by an empty shell's
        # successful pipeline status. Reset is still available after this error.
        with self.phase("negative-missing-decoder"):
            self.open(); self.boot()
            successful(self.run("rm -f /bin/base64"), "deliberately remove transport decoder")
            result = self.call("executeExpression", "1 + 1")
            require(result.get("status") == 127, f"missing decoder did not report guest command-not-found: {result}")
            require(self.page.evaluate("window.redoxDemo.state") == "ready", "missing guest tool destroyed the live terminal")
            self.evidence["negative"].append({"kind": "missing-decoder", "result": result})
            self.retain("missing-decoder"); self.call("stop")
        # Missing Snix is not an allowed skip: remove it in the actual running guest.
        self.open(); self.boot()
        successful(self.run("rm -f /bin/snix"), "deliberately remove Snix")
        result = self.call("executeExpression", "1 + 1")
        require(result.get("status") == 127, f"missing Snix did not report guest command-not-found: {result}")
        self.evidence["negative"].append({"kind": "missing-snix", "result": result})
        self.retain("missing-snix"); self.call("stop")


@contextmanager
def isolation_tree(site):
    # A temporary deployment, not mocked responses and never a source mutation.
    import os
    import tempfile
    with tempfile.TemporaryDirectory(prefix="redox-isolation-") as temporary:
        root = Path(temporary)
        source = Path(site).resolve()
        for path in source.rglob("*"):
            target = root / path.relative_to(source)
            if path.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                if path.name == "coi-serviceworker.js":
                    target.write_bytes(path.read_bytes())
                else:
                    os.symlink(path, target)
        yield root


def routing_proof(args, browser):
    """Use real browser fetch/navigation against a mutable channel deployment."""
    import os
    with isolation_tree(args.site) as root, server(root, port=0, prefix=args.prefix) as http:
        threading.Thread(target=http.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{http.server_port}/{args.prefix.strip('/')}/"
        context = browser.new_context(service_workers="block")
        page = context.new_page()
        try:
            pointer = json.loads((root / "channel.json").read_bytes())
            revision = pointer["revision"]
            suffix = "?routing=" + secrets.token_hex(8) + "#preserved-fragment"
            page.goto(urljoin(base, "live/") + suffix, wait_until="domcontentloaded")
            page.wait_for_function("!!window.redoxDemo", timeout=30000)
            final = page.url
            require(final == urljoin(base, f"revisions/{revision}/live/") + suffix, f"mutable channel did not select exact immutable revision or preserve search/hash: {final}")
            probe = page.evaluate("""async base => {
              const headers={'If-Modified-Since':'Fri, 01 Jan 2100 00:00:00 GMT'};
              const channel=await fetch(new URL('channel.json',base),{headers,cache:'no-store'});
              const pointer=await channel.json();
              const entry=await fetch(new URL('live/',base),{headers,cache:'no-store'});
              const manifestResponse=await fetch(new URL(pointer.manifest.url,base));
              const raw=await manifestResponse.arrayBuffer();
              const sha256=[...new Uint8Array(await crypto.subtle.digest('SHA-256',raw))].map(x=>x.toString(16).padStart(2,'0')).join('');
              const manifest=JSON.parse(new TextDecoder().decode(raw));
              const wasm=await fetch(new URL(manifest.assets.wasm.url,new URL(pointer.manifest.url,base)),{method:'HEAD'});
              return {channel:{status:channel.status,cache:channel.headers.get('Cache-Control'),pointer},entry:{status:entry.status,cache:entry.headers.get('Cache-Control')},manifestHash:sha256,wasm:{status:wasm.status,mime:wasm.headers.get('Content-Type'),cache:wasm.headers.get('Cache-Control')}};
            }""", base)
            for role in ("channel", "entry"):
                require(probe[role]["status"] == 200 and "no-store" in (probe[role]["cache"] or ""), f"mutable {role} returned stale conditional content: {probe[role]}")
            require(probe["manifestHash"] == pointer["manifest"]["sha256"], "channel navigation did not select pinned manifest bytes")
            require(probe["wasm"]["status"] == 200 and probe["wasm"]["mime"].split(";")[0] == "application/wasm" and "immutable" in probe["wasm"]["cache"], "browser deployment does not serve immutable WASM with its real MIME")
            # Simulate a later channel whose revision has become unavailable. Keep
            # epoch-one mtime to exercise the Nix weak-timestamp failure directly.
            unavailable = secrets.token_hex(32)
            changed = {**pointer, "revision": unavailable,
                       "manifest": {**pointer["manifest"], "url": f"revisions/{unavailable}/manifest.json"}}
            channel = root / "channel.json"
            channel.unlink()
            channel.write_text(json.dumps(changed))
            os.utime(channel, (1, 1))
            missing = context.new_page()
            missing.goto(urljoin(base, "live/"), wait_until="domcontentloaded")
            missing.wait_for_selector("#status[role=alert]", timeout=30000)
            error = missing.locator("#status").inner_text()
            require(unavailable in error and "unavailable" in error.lower(), "unavailable new revision did not produce actionable visible bootstrap failure")
            require(missing.locator("a[href='../#demo']").count() == 1 and missing.evaluate("typeof window.redoxDemo") == "undefined", "failed mutable bootstrap loaded VM code or omitted recordings access")
            page.reload(wait_until="domcontentloaded")
            page.wait_for_function("!!window.redoxDemo", timeout=30000)
            require(page.url == final, "saved immutable revision followed the later channel")
            return {"kind": "real-browser-channel-routing", "selectedURL": final, "headers": probe,
                    "laterUnavailableRevision": unavailable, "visibleError": error, "savedRevisionURL": page.url}
        finally:
            context.close(); http.shutdown()


def isolation_proof(args, browser):
    """Exercise actual SW first control, revision scope, update and fail-closed host."""
    records = []
    with isolation_tree(args.site) as root, server(root, port=0, prefix=args.prefix, isolation=False) as http:
        threading.Thread(target=http.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{http.server_port}/{args.prefix.strip('/')}/"
        pointer = json.loads((Path(args.site) / "channel.json").read_bytes())
        revision = pointer["revision"]
        for relative in ("live/", f"revisions/{revision}/live/"):
            context = browser.new_context(service_workers="allow")
            page = context.new_page()
            try:
                page.goto(urljoin(base, relative), wait_until="domcontentloaded")
                page.wait_for_function("crossOriginIsolated && !!navigator.serviceWorker.controller", timeout=30000)
                info = page.evaluate("({isolated:crossOriginIsolated,url:location.href,controller:navigator.serviceWorker.controller.scriptURL})")
                expected = urljoin(info["url"], "../coi-serviceworker.js")
                require(info["controller"] == expected, f"wrong isolation scope controlled revision: {info}")
                query = """() => new Promise((resolve,reject)=>{const channel=new MessageChannel();const timer=setTimeout(()=>reject(Error('worker version reply timeout')),3000);channel.port1.onmessage=event=>{clearTimeout(timer);resolve(event.data)};navigator.serviceWorker.controller.postMessage({type:'redox-isolation-version'},[channel.port2]);})"""
                before = page.evaluate(query)
                require(before["version"] == "redox-isolation-v1", "unexpected first-visit isolation worker version")
                worker_path = root / urlsplit(expected).path.removeprefix(urlsplit(base).path)
                original = worker_path.read_text()
                worker_path.write_text(original.replace("redox-isolation-v1", "redox-isolation-update-proof-v1"))
                page.evaluate("async () => { window.previousIsolationController=navigator.serviceWorker.controller; const registration=await navigator.serviceWorker.getRegistration(location.href); await registration.update(); }")
                page.wait_for_function("navigator.serviceWorker.controller !== window.previousIsolationController", timeout=30000)
                after = page.evaluate(query)
                require(after["version"] == "redox-isolation-update-proof-v1", "worker update did not become active")
                records.append({"kind": "first-visit-scoped-update", **info, "before": before, "after": after})
                worker_path.write_text(original)
            finally:
                context.close()
        context = browser.new_context(service_workers="block")
        page = context.new_page()
        try:
            page.goto(urljoin(base, "live/"), wait_until="domcontentloaded")
            page.wait_for_function("!!window.redoxDemo", timeout=30000)
            result = page.evaluate("""async () => {let timer;try {await Promise.race([window.redoxDemo.boot({mode:'cold'}),new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('isolation rejection deadline')),30000)})]);return {unexpectedSuccess:true};} catch(error) {return {error:String(error),state:window.redoxDemo.state,diagnostic:window.redoxDemo.diagnostics(),serial:window.redoxDemo.transcript};} finally {clearTimeout(timer);} }""")
            require(not result.get("unexpectedSuccess") and result.get("state") == "failed", f"unsupported isolation host did not fail explicitly: {result}")
            require(READY not in result.get("serial", ""), "unsupported host launched guest")
            records.append({"kind": "missing-isolation", **result})
        finally:
            context.close(); http.shutdown()
    return records


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("site", help="built browser-site deploy tree")
    p.add_argument("--output", default="browser-evidence")
    p.add_argument("--chromium", required=True, help="real Chromium executable")
    p.add_argument("--prefix", default="/redox-preview/")
    p.add_argument("--disk-backend", choices=("preload", "lazy"), default="preload")
    p.add_argument("--boot-timeout", type=int, default=600, help="execution bound, not a performance budget")
    p.add_argument("--command-timeout", type=int, default=120)
    p.add_argument("--fixture-timeout", type=int, default=900)
    p.add_argument("--cycles", type=int, default=3)
    p.add_argument("--quiescence-ms", type=int, default=1000)
    p.add_argument("--sleep-seconds", type=int, default=16, help="external clock interval; amortizes command and scheduling jitter")
    p.add_argument("--clock-tolerance", type=float, default=.35, help="correctness ratio tolerance, not regression budget")
    p.add_argument("--no-sandbox", action="store_true", help="only for a disposable runner without Chromium sandbox support")
    args = p.parse_args()
    require(args.cycles >= 2, "at least two lifecycle repetitions are mandatory")
    require(args.sleep_seconds >= 4 and args.sleep_seconds % 4 == 0, "sleep-seconds must be a positive multiple of four")
    require(0 < args.clock_tolerance < .5, "clock tolerance must detect proportional 4x fault")
    from playwright.sync_api import sync_playwright
    with server(args.site, port=0, prefix=args.prefix) as http:
        threading.Thread(target=http.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{http.server_port}/{args.prefix.strip('/')}/"
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(executable_path=args.chromium, headless=True, args=["--no-sandbox"] if args.no_sandbox else [])
            h = Harness(args, browser, base)
            try:
                h.open()
                h.direct_preflight()
                with h.phase("deployment-contract"):
                    isolation = h.page.evaluate("({isolated:crossOriginIsolated,secure:isSecureContext,shared:typeof SharedArrayBuffer==='function'})")
                    require(all(isolation.values()), f"missing browser isolation/capabilities: {isolation}")
                    h.evidence["isolation"] = isolation
                with h.phase("browser-current-revision-routing-and-cache"):
                    h.evidence["routing"] = routing_proof(args, browser)
                h.exercise("cold", disk_backend=args.disk_backend)
                # A reused context retains the actual browser cache; first boot is cold-download,
                # later full cold guest boots measure warm-cache without pretending to snapshot.
                h.open(); h.exercise("cold", disk_backend=args.disk_backend)
                if h.evidence["manifest"].get("snapshot"):
                    h.open(); h.exercise("snapshot")
                h.negative()
                with h.phase("pages-isolation-first-visit-update-scope"):
                    h.evidence["isolationFallback"] = isolation_proof(args, browser)
                h.evidence["success"] = True
            except Exception as error:
                h.evidence["failure"] = str(error)
                raise
            finally:
                h.retain("final")
                h.context.close(); browser.close(); http.shutdown()


if __name__ == "__main__":
    main()
