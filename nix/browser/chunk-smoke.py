#!/usr/bin/env python3
"""Bounded real-Chromium/Redox preload versus chunk-disk proof.

Requires an extended immutable release with browser-chunk, diskChunks and the
ordinary serial browser-demo fixtures. All I/O originates in the real guest;
frame instrumentation only observes the production ChunkDisk. It never supplies
bytes, changes policy limits or invokes a synthetic block device.
No performance improvement is asserted. Run through the browser smoke Python
closure (Playwright required), not the host's arbitrary Python environment.
"""
import argparse
import base64
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import secrets
import shlex
import threading
import time
from urllib.parse import urljoin

from serve import server
from smoke import Harness, READY, require, successful

FLUSH = "/nix/system/profile/bin/browser-demo-flush"
STORE_STREAM = r"""set -euo pipefail
read_tree() {
    local entry
    for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
        if test -L "$entry"; then continue
        elif test -d "$entry"; then read_tree "$entry"
        elif test -f "$entry"; then cat "$entry"
        fi
    done
}
read_tree /nix/store > /dev/null
"""

# Install before frame.js handles initialize, so observation cannot miss early
# firmware reads. Redispatch the exact real config after importing the SAME ES
# module URL used by frame.js. No replacement constructor, responses or callbacks.
PROBE = r"""(() => {
  if (window === parent) {
    window.__chunkProof = {events:[],errors:[],samples:[],transfers:[],last:null,
      counts:{},writeIndices:{},cacheEvictions:0,droppedEvents:0,overflow:false};
    return;
  }
  if (!/\/frame\.html$/.test(location.pathname)) return;
  let replay = false;
  addEventListener('message', async event => {
    if (replay || event.source !== parent || event.origin !== location.origin ||
        event.data?.channel !== 'redox-vm' || event.data.type !== 'initialize') return;
    event.stopImmediatePropagation();
    try {
      const {ChunkDisk} = await import(new URL('./chunk-disk.js',location.href));
      const report = parent.__chunkProof;
      const session = new URL(location.href).searchParams.get('session');
      const append = (key,value,limit=20000) => {
        if (report[key].length < limit) report[key].push({session,time:performance.now(),...value});
        else if(key==='events') report.droppedEvents++;
        else report.overflow=true;
      };
      let disk, sequence=0;
      const summary = () => disk ? {stats:disk.stats,limits:{cleanCacheBytes:disk.cleanCacheBytes,
        dirtyLimitBytes:disk.dirtyLimitBytes,concurrency:disk.concurrency,maxPending:disk.maxPending},
        logicalSize:disk.logicalSize,imageSha256:disk.imageSha256,chunkSize:disk.manifest.chunkSize} : null;
      const sample = () => {
        const value=summary();
        if(value) {report.last={session,...value};append('samples',value);}
      };
      const bind = value => {
        if(disk) return;
        disk=value;
        // Observe existing policy only; no replacement or smaller test quota.
        sample();
      };
      for(const name of ['read','write','flush','close','chunk']) {
        const original=ChunkDisk.prototype[name];
        ChunkDisk.prototype[name]=function(...args) {
          bind(this);
          const id=++sequence;
          const op={id,op:name,offset:args[0]??null,
            length:name==='write'?args[1].byteLength:name==='read'?args[1]:0};
          const keys=name==='chunk'?new Set(this.state.cache.keys()):null;
          const complete=()=>{
            report.counts[name]=(report.counts[name]||0)+1;
            if(name==='write' && op.length) {
              const size=this.manifest.chunkSize;
              for(let i=Math.floor(op.offset/size);i<=Math.floor((op.offset+op.length-1)/size);i++) report.writeIndices[i]=true;
            }
            if(keys) for(const key of keys) if(!this.state.cache.has(key)) report.cacheEvictions++;
            append('events',{...op,stage:'complete'});
          };
          const rejected=error=>{
            const value={...op,stage:'error',errno:error.errno??null,error:String(error),
              hostTimeMs:performance.timeOrigin+performance.now()};
            append('events',value);append('errors',value);sample();throw error;
          };
          append('events',{...op,stage:'begin'});
          try {
            const result=original.apply(this,args);
            if(name==='close') {complete();sample();return result;}
            return Promise.resolve(result).then(value=>{complete();return value;},rejected);
          } catch(error) {return rejected(error);}
        };
      }
      performance.setResourceTimingBufferSize(20000);
      const observer=new PerformanceObserver(list=>{
        for(const x of list.getEntries()) append('transfers',{name:x.name,startTime:x.startTime,
          transferSize:x.transferSize,encodedBodySize:x.encodedBodySize,
          decodedBodySize:x.decodedBodySize,duration:x.duration});
      });
      observer.observe({type:'resource',buffered:true});
      addEventListener('resourcetimingbufferfull',()=>{report.overflow=true;});
      const timer=setInterval(sample,250);
      addEventListener('pagehide',()=>{sample();clearInterval(timer);observer.disconnect();},{once:true});
      replay=true;
      dispatchEvent(new MessageEvent('message',{data:event.data,origin:event.origin,source:event.source}));
      replay=false;
    } catch(error) {
      parent.__chunkProof.errors.push({stage:'instrumentation-error',error:String(error)});
      throw error;
    }
  },true);
})();"""


def lines(text):
    return text.replace("\r", "").splitlines()


def proof(h):
    return h.page.evaluate("window.__chunkProof")


def ready(h):
    state = h.page.evaluate("window.redoxDemo.state")
    require(state == "ready", f"guest is not ready: {state}")
    require(READY in lines(h.page.evaluate("window.redoxDemo.transcript")), "real serial readiness marker absent")


@contextmanager
def sampled_memory(h):
    """Sample actual Chromium process tree RSS/PSS while Playwright is blocked.

    Use the same Linux smaps_rollup fields as Harness.process_memory. Never call
    Playwright from the sampler thread, and never label JS heap as total memory.
    """
    processes = h.cdp.send("SystemInfo.getProcessInfo")["processInfo"]
    roots = [int(p["id"]) for p in processes if p.get("type") == "browser"]
    require(roots, "CDP did not identify the launched browser process")
    stop = threading.Event()
    samples = []

    def collect():
        while not stop.is_set():
            pending, seen, values, unavailable = list(roots), set(), [], []
            while pending:
                pid = pending.pop()
                if pid in seen:
                    continue
                seen.add(pid)
                try:
                    pending.extend(map(int, Path(f"/proc/{pid}/task/{pid}/children").read_text().split()))
                    fields = {}
                    for line in Path(f"/proc/{pid}/smaps_rollup").read_text().splitlines():
                        key, _, value = line.partition(":")
                        if key in ("Rss", "Pss"):
                            fields[key] = int(value.split()[0]) * 1024
                    if len(fields) == 2:
                        values.append({"pid": pid, **fields})
                except (OSError, ValueError) as error:
                    unavailable.append({"pid": pid, "error": str(error)})
            samples.append({"monotonic": time.monotonic(), "available": bool(values),
                            "rssBytes": sum(p["Rss"] for p in values) if values else None,
                            "pssBytes": sum(p["Pss"] for p in values) if values else None,
                            "processes": values, "unavailable": unavailable})
            stop.wait(.5)

    worker = threading.Thread(target=collect, daemon=True)
    worker.start()
    try:
        yield samples
    finally:
        stop.set()
        worker.join(timeout=5)
        require(not worker.is_alive(), "memory sampler failed to stop")
        h.evidence.setdefault("memorySampling", []).append({"intervalSeconds": .5, "samples": samples,
            "scope": "launched Chromium browser process and observed Linux descendants; RSS double counts shared pages",
            "peakIsSampledNotHighWaterMark": True})
        require(any(sample["available"] for sample in samples), "real Chromium process RSS/PSS unavailable; inspect retained memory sampling prerequisites")


def inventory(h):
    h.direct_preflight()
    manifest = h.evidence["manifest"]
    require("browser-chunk" in manifest.get("engineFeatures", []), "release requires the compiled browser-chunk driver")
    pin = manifest["assets"].get("diskChunks")
    require(pin, "release has no pinned diskChunks manifest")
    manifest_url = urljoin(h.page.url, "../manifest.json")
    url = urljoin(manifest_url, pin["url"])
    response = h.context.request.get(url, timeout=h.args.command_timeout * 1000)
    require(response.ok, f"chunk manifest unavailable: {response.status}")
    raw = response.body()
    require(len(raw) == pin["size"] and hashlib.sha256(raw).hexdigest() == pin["sha256"], "chunk manifest pin mismatch")
    chunks = json.loads(raw)
    disk = manifest["assets"]["disk"]
    require(chunks["imageSha256"] == disk.get("rawSha256", disk["sha256"]), "preload/lazy image hashes differ")
    require(chunks["logicalSize"] == disk.get("logicalSize", disk["size"]), "preload/lazy image sizes differ")
    require(chunks["chunkSize"] <= 16777216, "unbounded chunk size")
    Path(h.args.output).mkdir(parents=True, exist_ok=True)
    (Path(h.args.output) / "chunk-manifest.raw.json").write_bytes(raw)
    h.evidence["chunkManifest"] = {"url": url, "pin": pin, "manifest": chunks}
    return manifest, chunks, url


def file_workflow(h, chunk_size, absent_paths):
    """Hash entire guest file; verify exact windows across file/chunk/sector edges.

    Filesystem offsets are not disk offsets. Real backend tracing separately
    requires writes on both sides of a physical chunk boundary; no assertion
    claims that a file seek is a sub-sector QEMU request.

    This fixture is ASCII, so Bash read -N advances exact byte counts without
    relying on absent dd/seek tools. Binary backend coverage is independent.
    """
    for path in absent_paths:
        successful(h.run(f"test ! -e {shlex.quote(path)}"), "other session's guest file must be absent")
    nonce = secrets.token_hex(12)
    path = "/playground/v1/.chunk-proof-" + nonce
    block = (nonce * 171)[:4096].encode()
    size = 2 * chunk_size + 1025
    count, tail = divmod(size, len(block))
    expected = bytearray(block * count + block[:tail])
    command = ("set -euo pipefail\n" + f"block='{block.decode()}'\nunit=$block\n"
               + "for ((i=0;i<8;i++)); do unit+=$unit; done\n"
               + f"for ((i=0;i<{count // 256};i++)); do printf '%s' \"$unit\"; done > {path}\n"
               + f"for ((i=0;i<{count % 256};i++)); do printf '%s' \"$block\"; done >> {path}\n"
               + f"printf '%s' '{block[:tail].decode()}' >> {path}\n{FLUSH} {path}\n")
    successful(h.run(command, h.args.fixture_timeout), "write real guest file exceeding two chunks")
    checkpoints = []
    for offset, data in ((511, (nonce + "sector-partial").encode()),
                         (chunk_size - 17, (nonce * 3).encode()),
                         (2 * chunk_size - 5, (nonce + "tail-preservation").encode())):
        encoded = base64.b64encode(data).decode()
        command = ("set -euo pipefail\n" + f"exec 3<> {path}\n"
                   + f"IFS= read -r -N {offset} -u 3 skipped\n"
                   + f"printf '%s' {shlex.quote(data.decode('ascii'))} >&3\n"
                   + f"exec 3>&-\n{FLUSH} {path}\n")
        successful(h.run(command), "partial guest overwrite through an existing descriptor")
        expected[offset:offset + len(data)] = data
        checkpoints.append({"offset": offset, "bytesBase64": encoded})
    hasher = hashlib.sha256(expected)
    digest = hasher.hexdigest()
    sri = "sha256-" + base64.b64encode(hasher.digest()).decode()
    # Use the seed Snix multicall hash command, not an absent sha256sum applet.
    output = successful(h.run(f"(exec -a nix /bin/snix hash file --type sha256 {path})\nwc -c < {path}"), "hash and size actual guest file")
    require(sri in lines(output), f"guest whole-file bytes differ: {output}")
    require(str(size) in [line.strip() for line in lines(output)], "partial write changed guest file length")
    hash_output = output
    windows = []
    for edge in (512, chunk_size, 2 * chunk_size):
        offset, length = max(0, edge - 64), 192
        encoded = base64.b64encode(expected[offset:offset + length]).decode()
        command = ("set -euo pipefail\n" + f"exec 3< {path}\n"
                   + f"IFS= read -r -N {offset} -u 3 skipped\n"
                   + f"IFS= read -r -N {length} -u 3 window\n"
                   + "exec 3<&-\nprintf '%s' \"$window\" | base64 -w0; printf '\\n'\n")
        output = successful(h.run(command), "read exact preserved guest boundary window")
        require(encoded in lines(output), "guest partial-write preservation window differs")
        windows.append({"offset": offset, "length": length, "output": output})
    h.evidence.setdefault("guestFiles", []).append({"path": path, "size": size, "sha256": digest,
        "patches": checkpoints, "checkedWindowEdges": [512, chunk_size, 2 * chunk_size],
        "hashOutput": hash_output, "windowReads": windows})
    return path


def verify_backend(h, chunk_size):
    report = proof(h)
    require(not report["overflow"], "chunk evidence overflow; no truncated proof is accepted")
    errors = report["errors"]
    require(not errors, f"successful guest workflow had disk errors: {errors}")
    require(report["counts"].get("write", 0), "guest workflow never reached real chunk block writes")
    touched = set(map(int, report["writeIndices"]))
    require(any(index + 1 in touched for index in touched), "no guest writes observed on both sides of a physical chunk boundary")
    require(report["samples"], "real backend samples missing")
    for sample in report["samples"]:
        stats, limits = sample["stats"], sample["limits"]
        require(stats["cleanCacheBytes"] <= limits["cleanCacheBytes"], "clean cache exceeded its configured bound")
        require(stats["dirtyOverlayBytes"] <= limits["dirtyLimitBytes"], "dirty overlay exceeded its configured bound")
        require(stats["inflight"] <= limits["concurrency"] and stats["pending"] <= limits["maxPending"], "backend concurrency bound exceeded")
    h.evidence["physicalChunkWriteIndices"] = sorted(touched)
    return report


def transfer_record(h, label):
    report = proof(h)
    top = h.page.evaluate("performance.getEntriesByType('resource').map(x=>({name:x.name,startTime:x.startTime,transferSize:x.transferSize,encodedBodySize:x.encodedBodySize,decodedBodySize:x.decodedBodySize,duration:x.duration}))")
    transfers = [{"document": "parent", **x} for x in top] + [{"document": "engine", **x} for x in report["transfers"]]
    h.evidence.setdefault("transferRuns", []).append({"label": label, "resources": transfers,
        "observedTransferBytes": sum(x["transferSize"] for x in transfers),
        "caveat": "ResourceTiming transferSize, including headers where exposed; zero can mean HTTP cache or service-worker delivery. Decoded backend bytes are recorded separately, not equated with wire bytes."})
    h.evidence["backendObservation"] = report
    h.evidence.setdefault("backendRuns", []).append({"label": label, "observation": report})
    h.resources(label)


def measured_runs(h, backend, chunks, previous_paths):
    paths = list(previous_paths)
    # One context per backend. First run is cold browser-context cache, the second
    # deliberately reuses that real cache, but never a guest disk/overlay.
    for temperature in ("cold-context", "warm-context"):
        label = f"{backend}-{temperature}"
        h.download_state = temperature
        with sampled_memory(h):
            with h.phase(label):
                h.boot("cold", disk_backend=backend)
                ready(h)
                h.correctness(label)  # Snix evaluation, mandatory offline fixtures, fresh builds.
                paths.append(file_workflow(h, chunks["chunkSize"], paths))
                if backend == "lazy":
                    verify_backend(h, chunks["chunkSize"])
                transfer_record(h, label)
                h.retain(label)
        h.stopped()
        # Navigation resets resource timing and proof counters, not HTTP cache.
        h.open()
    # Explicit reset has its own guest proof and isolation checks.
    h.boot("cold", disk_backend=backend)
    marker = file_workflow(h, chunks["chunkSize"], paths)
    old = h.page.evaluate("window.redoxDemo.sessionId")
    h.call("reset")
    ready(h)
    new = h.page.evaluate("window.redoxDemo.sessionId")
    require(new != old, "reset reused the old VM session")
    successful(h.run(f"test ! -e {marker}"), "reset discarded prior real guest file")
    value = secrets.randbelow(10**8)
    require(str(value + 17) in lines(successful(h.call("executeExpression", f"{value} + 17"), "Snix after reset")), "reset Snix output stale")
    h.evidence["resetIsolation"] = {"oldSession": old, "newSession": new, "absentPath": marker}
    transfer_record(h, f"{backend}-reset")
    h.stopped()
    return paths + [marker]


def dirty_limit(h, chunks):
    h.open()
    h.boot("cold", disk_backend="lazy")
    h.page.wait_for_function("window.__chunkProof.last!==null")
    stats = proof(h)["last"]
    limit = stats["limits"]["dirtyLimitBytes"]
    # df cannot enumerate Redox mounts. Only a rejected real backend write
    # proves this case; guest filesystem exhaustion alone must still fail.
    # Repeating a 1 MiB Bash string produced a 68 MiB file but only 5 MiB of
    # distinct dirty sectors. Read fresh random bytes with the installed Bash;
    # its C locale makes read -N and string lengths byte-based. NULs are skipped.
    maximum = limit + 4 * 1048576
    path = "/playground/v1/.quota-" + secrets.token_hex(8)
    command = ("set -euo pipefail\nexport LC_ALL=C\nexec 3</scheme/rand\n"
               + f"remaining={maximum}\n"
               + "while ((remaining>0)); do\n"
               + "size=$((remaining>1048576 ? 1048576 : remaining))\n"
               + "IFS= read -r -N \"$size\" -u 3 block || exit\n"
               + "[[ ${#block} -eq $size ]] || exit 65\n"
               + "printf '%s' \"$block\" || exit\n"
               + "remaining=$((remaining-size))\ndone > " + path + "\nexec 3<&-\n"
               + f"{FLUSH} {path}")
    start = len(proof(h)["errors"])
    try:
        result = h.run(command, h.args.fixture_timeout)
    except Exception as error:
        result = {"status": "rejected", "error": str(error)}
    report = proof(h)
    errors = [e for e in report["errors"][start:] if e.get("op") == "write" and e.get("errno") == 28]
    diagnostics = h.call("diagnostics")
    state = diagnostics["state"]
    failure_delay_ms = (h.page.evaluate("performance.timeOrigin+performance.now()") - errors[0]["hostTimeMs"]
                        if errors else None)
    h.evidence["dirtyLimitOutcome"] = {"configuredBytes": limit, "maximumFileBytes": maximum,
        "guestSource": "/scheme/rand", "guestPath": path, "ioErrors": errors,
        "guestResult": result, "state": state, "failureDeliveryMs": failure_delay_ms}
    h.evidence["backendObservation"] = report
    require(errors, "guest did not reach a real ENOSPC block write at the unchanged dirty limit")
    require((isinstance(result.get("status"), int) and 0 < result["status"] <= 255) or
            (result.get("status") == "rejected" and state == "failed"),
            f"guest silently accepted quota-failed writes: {result}")
    require(state == "failed" and 0 <= failure_delay_ms <= 10000,
            f"backend write failure did not promptly fail its owning session: {failure_delay_ms} ms")
    require(diagnostics["resources"]["pendingCommands"] == 0 and diagnostics["resources"]["trackedFrames"] == 0,
            "failed disk session retained a pending command or VM frame")
    h.retain("dirty-limit")
    old_session = h.page.evaluate("window.redoxDemo.sessionId")
    h.call("reset")
    h.page.wait_for_function("window.redoxDemo.state==='ready'", timeout=h.args.boot_timeout * 1000)
    new_session = h.page.evaluate("window.redoxDemo.sessionId")
    require(new_session and new_session != old_session, "quota reset reused the failed disk session")
    h.evidence["sessions"].append(new_session)
    successful(h.run(f"test ! -e {shlex.quote(path)}"), "quota reset must discard partial guest file")
    nonce = secrets.randbelow(10**8) + 1
    resumed = h.call("executeExpression", f"{nonce} * 3 + 7")
    require(str(nonce * 3 + 7) in lines(successful(resumed, "fresh guest after quota reset")),
            "quota reset did not execute the fresh guest nonce")
    h.evidence["dirtyLimitOutcome"]["reset"] = {"oldSession": old_session, "newSession": new_session,
        "discardedPath": path, "nonce": nonce, "expected": nonce * 3 + 7, "result": resumed}
    h.stopped()



def fault_run(h, chunks, chunk_url, kind):
    h.open()
    held, intercepted = [], []
    # A real chunk belonging to another object is the stale response, not a
    # fabricated manifest or a replacement block device.
    nonzero = [c for c in chunks["chunks"] if not c["zero"]]
    require(len({c["sha256"] for c in nonzero}) > 1, "stale-object proof needs two distinct real chunk objects")

    def route(request):
        if intercepted and request.request.url != intercepted[0]["url"]:
            request.continue_()
            return
        require(len(intercepted) < 1000, "fault retry evidence bound exceeded")
        intercepted.append({"url": request.request.url, "kind": kind})
        if kind == "cancel":
            held.append(request)
            return
        if kind == "missing":
            request.fulfill(status=404, body=b"chunk proof: missing immutable object")
            return
        response = request.fetch(timeout=h.args.command_timeout * 1000)
        require(response.ok, "fault source chunk itself unavailable")
        body = response.body()
        if kind == "truncated":
            body = body[:-1]
        elif kind == "corrupt":
            require(body, "cannot corrupt an empty chunk")
            body = bytes([body[0] ^ 1]) + body[1:]
        else:
            other = next(c for c in nonzero if not request.request.url.endswith(c["sha256"]))
            stale = h.context.request.get(urljoin(chunk_url, other["url"]), timeout=h.args.command_timeout * 1000)
            require(stale.ok, "stale real object unavailable")
            body = stale.body()
            require(len(body) == other["length"] and hashlib.sha256(body).hexdigest() == other["sha256"], "stale source is not the pinned other real chunk")
            intercepted[-1]["staleSha256"] = hashlib.sha256(body).hexdigest()
        # Omit original transfer/content-length headers: this is a real HTTP
        # response with the bad decoded body whose integrity the backend checks.
        request.fulfill(status=200, content_type="application/octet-stream", body=body)

    pattern = urljoin(chunk_url, "chunks/*")
    h.page.route(pattern, route)
    started = time.monotonic()
    h.page.evaluate("bound=>{window.__chunkBootOutcome={status:'pending'};window.redoxDemo.boot({mode:'cold',diskBackend:'lazy',coldFallback:false,bootTimeoutMs:bound}).then(()=>{window.__chunkBootOutcome={status:'resolved'};},error=>{window.__chunkBootOutcome={status:'rejected',error:String(error)};});}", h.args.boot_timeout * 1000)
    try:
        if kind == "cancel":
            h.page.wait_for_function("window.__chunkProof.samples.some(x=>x.stats.inflight>0)", timeout=h.args.boot_timeout * 1000)
            require(held, "cancellation did not hold an actual chunk HTTP request")
            before = proof(h)
            h.stopped()  # shared teardown/worker/quiescence gate, while real read pending.
            outcome = h.page.evaluate("window.__chunkBootOutcome")
            require(outcome["status"] == "rejected", "canceled actual VM boot did not reject")
            report = proof(h)
            require(any(e.get("op") == "close" and e["stage"] == "complete" for e in report["events"]), "real disk close/cancellation not observed")
            h.evidence["cancellationOutcome"] = {"beforeStop": before, "afterStop": report, "bootOutcome": outcome}
        else:
            h.page.wait_for_function("window.redoxDemo.state==='failed'||window.redoxDemo.state==='ready'", timeout=(h.args.boot_timeout + 10) * 1000)
            state = h.page.evaluate("window.redoxDemo.state")
            report = proof(h)
            errors = [e for e in report["errors"] if e.get("errno") == 5 and e.get("op") == "read"]
            require(intercepted and errors, f"{kind} never produced a real device read EIO")
            require(state == "failed", f"{kind} silently reached ready after real disk I/O error")
            require(h.page.evaluate("window.__chunkBootOutcome.status") == "rejected", "failed VM left boot outcome pending/resolved")
            diagnostic = h.call("diagnostics")
            require(diagnostic.get("error"), "failed execution has no visible lifecycle error")
            h.evidence["faultOutcome"] = {"kind": kind, "state": state, "requests": intercepted,
                "ioErrors": errors, "diagnostics": diagnostic,
                "elapsedSeconds": time.monotonic() - started,
                "failureClass": "boot-deadline-after-observed-EIO" if "timed out" in diagnostic["error"].lower() else "explicit-runtime-failure-after-observed-EIO",
                "note": "C bridge returns EIO; it does not directly fail the UI. Guest boot deadline may supply the failed lifecycle state."}
            h.evidence["backendObservation"] = report
        h.retain(kind)
        if kind != "cancel":
            h.stopped()
    finally:
        for request in held:
            try:
                request.abort("aborted")
            except Exception:
                pass
        h.page.unroute_all(behavior="wait")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("site", help="extended built browser-site deployment containing diskChunks")
    parser.add_argument("--chromium", required=True)
    parser.add_argument("--output", default="browser-chunk-evidence")
    parser.add_argument("--prefix", default="/redox-chunk-preview/")
    parser.add_argument("--boot-timeout", type=int, default=600)
    parser.add_argument("--command-timeout", type=int, default=120)
    parser.add_argument("--fixture-timeout", type=int, default=900)
    parser.add_argument("--quiescence-ms", type=int, default=1000)
    parser.add_argument("--sleep-seconds", type=int, default=16, help="external clock interval; amortizes command and scheduling jitter")
    parser.add_argument("--clock-tolerance", type=float, default=.35)
    args = parser.parse_args()
    require(all(getattr(args, key) > 0 for key in ("boot_timeout", "command_timeout", "fixture_timeout", "quiescence_ms")), "deadlines must be positive")
    require(args.sleep_seconds >= 4 and args.sleep_seconds % 4 == 0, "sleep-seconds must be a positive multiple of four")
    require(0 < args.clock_tolerance < .5, "clock tolerance must detect proportional fault")
    from playwright.sync_api import sync_playwright
    root = Path(args.output)
    root.mkdir(parents=True, exist_ok=True)
    summary = {"kind": "browser-chunk-guest", "success": False, "runs": [],
        "claims": "bounded real guest execution only; no claimed speed/memory improvement or durable overlay persistence",
        "nonClaims": ["file partial overwrite is not a sub-sector QEMU request (driver alignment is 512)",
                      "queue saturation and arbitrary sub-sector backend operations are not claimed as guest execution",
                      "pure chunk backend unit tests are separate evidence, never substituted for these guest runs"]}
    binding = None
    paths = []
    with server(args.site, port=0, prefix=args.prefix) as http:
        threading.Thread(target=http.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{http.server_port}/{args.prefix.strip('/')}/"
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(executable_path=args.chromium, headless=True)
            try:
                for label in ("preload", "lazy", "missing", "truncated", "corrupt", "stale", "cancel", "cache-limit", "dirty-limit"):
                    run_args = argparse.Namespace(**vars(args))
                    run_args.output = str(root / label)
                    h = Harness(run_args, browser, base)
                    h.context.add_init_script(script=PROBE)
                    h.evidence.update(kind="browser-chunk-guest", scenario=label)
                    try:
                        h.open()
                        manifest, chunks, chunk_url = inventory(h)
                        current = {"revision": manifest["revision"], "machineHash": manifest["machineHash"],
                            "runtimeRevision": manifest["runtimeRevision"], "imageSha256": chunks["imageSha256"],
                            "ramMiB": manifest["machine"]["ramMiB"]}
                        if binding is None:
                            binding = current
                        require(current == binding, "comparison silently changed engine/machine/image/RAM")
                        summary["binding"] = binding
                        if label in ("preload", "lazy"):
                            paths = measured_runs(h, label, chunks, paths)
                        elif label == "cache-limit":
                            h.boot("cold", disk_backend="lazy")
                            ready(h)
                            h.correctness(label)
                            file_workflow(h, chunks["chunkSize"], paths)
                            # Stream real immutable guest files; the unchanged
                            # clean cache must evict, never silently grow.
                            successful(h.run(STORE_STREAM, h.args.fixture_timeout), "stream real guest store through device/cache")
                            report = verify_backend(h, chunks["chunkSize"])
                            require(report["cacheEvictions"] > 0, "guest store working set did not exercise the unchanged clean-cache eviction policy; larger real readable working set required")
                            h.evidence["cacheLimitOutcome"] = {"observedEvictions": report["cacheEvictions"], "policy": report["last"]["limits"]}
                            transfer_record(h, label)
                            h.stopped()
                        elif label == "dirty-limit":
                            dirty_limit(h, chunks)
                        else:
                            fault_run(h, chunks, chunk_url, label)
                        h.evidence["success"] = True
                        summary["runs"].append({"scenario": label, "success": True, "evidence": f"{label}/evidence.json"})
                    except Exception as error:
                        h.evidence["failure"] = str(error)
                        summary["runs"].append({"scenario": label, "success": False, "error": str(error), "evidence": f"{label}/evidence.json"})
                    finally:
                        try:
                            h.evidence["lastBackendObservation"] = proof(h)
                        except Exception as error:
                            h.evidence["backendEvidenceError"] = str(error)
                        h.retain("final")
                        h.context.close()
                        (root / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
                summary["success"] = all(run["success"] for run in summary["runs"])
                require(summary["success"], "chunk guest proof failed: " + ", ".join(run["scenario"] for run in summary["runs"] if not run["success"]))
            finally:
                browser.close()
                http.shutdown()
                (root / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")


if __name__ == "__main__":
    main()
