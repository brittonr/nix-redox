#!/usr/bin/env python3
"""Real PS/2 -> Orbital -> orbterm -> shell -> Snix proof in Chromium.

The serial channel only observes the graphical proof's files; it never submits
its commands. Harness.boot also performs its separate, ordinary serial preflight.
Framebuffer PNGs are evidence for human layout/pointer review, not image heuristics.
"""
import argparse
import base64
from pathlib import Path
import secrets
import shlex
import threading
import time

from serve import server
from smoke import BASH, READY, Harness, assert_fixtures, require, successful

GRAPHICAL_SHELL_READY_FILE = "/tmp/browser-graphical-shell-ready"
GRAPHICAL_SHELL_READY = "REDOX_BROWSER_GRAPHICAL_SHELL_READY:v1:uid=0"


# Physical US keys supported by display.js. Never insert_text(), paste, dispatch
# synthetic KeyboardEvents, or send the graphical command through serial.
UNSHIFTED = dict(zip("`-=[]\\;',./", ["Backquote", "Minus", "Equal", "BracketLeft",
    "BracketRight", "Backslash", "Semicolon", "Quote", "Comma", "Period", "Slash"]))
SHIFTED = dict(zip('~_+{}|:"<>?', ["Backquote", "Minus", "Equal", "BracketLeft",
    "BracketRight", "Backslash", "Semicolon", "Quote", "Comma", "Period", "Slash"]))
SHIFTED.update(dict(zip('!@#$%^&*()', [f"Digit{x}" for x in "1234567890"])))


def physical_key(character):
    if "a" <= character <= "z":
        return "Key" + character.upper()
    if "A" <= character <= "Z":
        return "Shift+Key" + character
    if "0" <= character <= "9":
        return "Digit" + character
    if character == " ":
        return "Space"
    if character in UNSHIFTED:
        return UNSHIFTED[character]
    if character in SHIFTED:
        return "Shift+" + SHIFTED[character]
    raise ValueError(f"Unsupported physical US keyboard character: {character!r}")


class GraphicalHarness(Harness):
    def __init__(self, args, browser, base):
        super().__init__(args, browser, base)
        self.context.set_default_timeout(args.command_timeout * 1000)
        self.evidence.update(kind="browser-orbital", graphicalRuns=[], screenshots=[],
            inputRuns=[], displaySamples=[], lifecycle=[],
            visualReview={"required": True, "scope": "Actual login/terminal layout, pointer and wheel behavior; PNGs are not automatic visual assertions"})
        self.evidence["resourceBounds"] = {"wasmHeapBytes": 3072 * 1024**2,
            "framebufferBytes": 1024 * 768 * 4, "inputRingBytes": (8 + 256 * 6) * 4,
            "guestRamMiB": 1024, "logicalDiskBytes": 1024**3}
        self.frame = None
        self.canvas = None

    def selected_machine(self):
        manifest = self.page.evaluate("""async () => {
          const response=await fetch(new URL('../manifest.json',location.href),{cache:'no-store'});
          if(!response.ok) throw Error('Graphical manifest unavailable');
          return await response.json();
        }""")
        self.evidence["selectedManifest"] = manifest
        machine = manifest["machine"]
        require(machine.get("display", {}).get("backend") == "redox-browser-rgba-v1",
                "This proof requires a site built with graphical-machine.json and browser-graphical-image")
        require(machine["display"].get("requestedMode") == {"width": 1024, "height": 768},
                "Graphical machine must request 1024x768")
        require(machine.get("input", {}).get("keyboard") == "ps2", "Graphical proof requires PS/2 keyboard")
        self.evidence["hardware"] = self.page.evaluate("""() => ({
          userAgent:navigator.userAgent,hardwareConcurrency:navigator.hardwareConcurrency,
          deviceMemoryGiB:navigator.deviceMemory??null,devicePixelRatio,
          isolated:crossOriginIsolated,secure:isSecureContext,shared:typeof SharedArrayBuffer==='function',
          screen:{width:screen.width,height:screen.height,colorDepth:screen.colorDepth}})""")
        require(all(self.evidence["hardware"][key] for key in ("isolated", "secure", "shared")),
                "Real graphical engine requires an isolated secure SharedArrayBuffer context")
        self.evidence["gpu"] = self.cdp.send("SystemInfo.getInfo")

    def sample(self, label):
        diagnostic = self.call("diagnostics")
        display = diagnostic.get("resources", {}).get("display")
        self.evidence["displaySamples"].append({"label": label, "hostMonotonic": time.monotonic(), "display": display})
        return display

    def measured_resources(self, label):
        display = self.sample(label)
        bounds = self.evidence["resourceBounds"]
        require(display is not None, "Actual display resource measurements unavailable")
        for name in ("wasmHeapBytes", "framebufferBytes", "inputRingBytes"):
            require(display[name] == bounds[name], f"Graphical {name} differs from measured fixed budget: {display[name]}")
        require(0 < display["wasmBreakBytes"] <= display["wasmHeapBytes"], "Allocator break unavailable or above heap ceiling")
        require(display["queueOverflows"] == 0, "Graphical input ring overflowed")
        self.resources(label)
        self.evidence.setdefault("allocatorMeasurements", []).append({"label": label,
            "breakBytes": display["wasmBreakBytes"], "maximumBreakBytes": display["maximumWasmBreakBytes"],
            "heapBytes": display["wasmHeapBytes"], "remainingBytes": display["wasmHeapBytes"] - display["wasmBreakBytes"],
            "caveat": "sbrk high-water reservation, not live allocation size; framebuffer is reused and input ring is static"})
        return display

    def display_ready(self, label):
        require(READY in self.page.evaluate("window.redoxDemo.transcript").replace("\r", "").splitlines(),
                "Actual guest serial readiness marker missing")
        self.page.wait_for_function("""() => {
          const d=window.redoxDemo.diagnostics().resources.display;
          return d?.inputConnected && !d.disposed && d.frames>0;
        }""", timeout=self.args.boot_timeout * 1000)
        iframe = self.page.locator("iframe.vm-frame")
        require(iframe.count() == 1, "Expected exactly one owned live VM iframe")
        self.frame = iframe.element_handle().content_frame()
        require(self.frame is not None, "Owned VM frame is unavailable")
        self.canvas = self.frame.locator("canvas.guest-framebuffer")
        require(self.canvas.count() == 1, "Graphical guest canvas is missing")
        self.frame.evaluate("""() => {
          window.__graphicalProofEvents=[];
          const canvas=document.querySelector('canvas.guest-framebuffer');
          for(const type of ['keydown','keyup','focus','blur','pointerdown','pointerup','pointermove','wheel']) {
            canvas.addEventListener(type,event=>{
              const events=window.__graphicalProofEvents;
              if(events.length>=32768) throw Error('Graphical proof event evidence bound exceeded');
              events.push({type,time:performance.now(),trusted:event.isTrusted,code:event.code??null,
                shift:!!event.shiftKey,ctrl:!!event.ctrlKey,alt:!!event.altKey,
                button:event.button??null,deltaX:event.deltaX??null,deltaY:event.deltaY??null});
            });
          }
        }""")
        mode = self.sample(label)
        self.evidence.setdefault("observedModes", []).append({"label": label, "width": mode["width"], "height": mode["height"],
            "requested": self.evidence["manifest"]["machine"]["display"]["requestedMode"]})
        # Retain the actual firmware-selected mode even when it violates the request.
        self.capture(label)
        require((mode["width"], mode["height"]) == (1024, 768),
                f"Firmware/guest did not select requested 1024x768: {mode['width']}x{mode['height']}; serial and PNG retained")
        require(mode.get("queueOverflows") == 0, "Graphical input ring overflowed")
        require(self.evidence["manifest"]["machine"]["ramMiB"] == 1024, "Graphical proof must retain 1024 MiB guest RAM")
        require(self.evidence["manifest"]["guestIdentity"]["logicalSize"] == 1024**3,
                "Graphical proof must retain the 1 GiB preload image")
        self.measured_resources(label + "-ready-resources")

    def capture(self, label):
        out = Path(self.args.output)
        out.mkdir(parents=True, exist_ok=True)
        index = len(self.evidence["screenshots"])
        record = {"label": label, "hostMonotonic": time.monotonic()}
        try:
            name = f"screen-{index:03d}-{label}.png"
            self.page.screenshot(path=str(out / name), full_page=True, timeout=self.args.command_timeout * 1000)
            record["browser"] = name
            canvas = self.canvas if self.frame is not None and not self.frame.is_detached() else None
            if canvas is None:
                iframe = self.page.locator("iframe.vm-frame")
                frame = iframe.element_handle().content_frame() if iframe.count() == 1 else None
                canvas = frame.locator("canvas.guest-framebuffer") if frame is not None else None
            if canvas is not None and canvas.count() == 1:
                encoded = canvas.evaluate("canvas=>canvas.toDataURL('image/png').split(',')[1]")
                name = f"framebuffer-{index:03d}-{label}.png"
                (out / name).write_bytes(base64.b64decode(encoded, validate=True))
                record["framebuffer"] = name
        except Exception as error:
            record["error"] = str(error)
            self.evidence["screenshots"].append(record)
            raise
        self.evidence["screenshots"].append(record)

    def retain_input(self, label):
        if self.frame is None or self.frame.is_detached():
            return
        events = self.frame.evaluate("window.__graphicalProofEvents.splice(0)")
        require(all(event["trusted"] for event in events), "Graphical proof received untrusted synthetic input")
        self.evidence["inputRuns"].append({"label": label, "events": events})

    def focus(self):
        self.canvas.focus(timeout=self.args.command_timeout * 1000)
        require(self.canvas.evaluate("canvas=>document.activeElement===canvas"), "Cannot establish browser canvas keyboard focus")

    def type_physical(self, text):
        start = time.monotonic()
        for character in text:
            require(time.monotonic() - start < self.args.command_timeout, "Graphical keyboard submission deadline exceeded")
            self.page.keyboard.press(physical_key(character), delay=self.args.key_delay_ms)
        self.evidence.setdefault("typing", []).append({"characters": len(text), "elapsedMs": (time.monotonic() - start) * 1000})

    def login(self, label):
        with self.phase(label + "-root-login"):
            successful(self.run(f"test ! -e {GRAPHICAL_SHELL_READY_FILE}"),
                       "graphical shell readiness must be absent before login in each pristine session")
            self.focus()
            # Pinned orbutils 77d4a56: Escape clears both fields and selects
            # username, even when the sole normal user was preselected. Enter
            # selects password, and a second Enter authenticates/launches orbterm.
            self.page.keyboard.press("Escape", delay=self.args.key_delay_ms)
            self.type_physical("root")
            self.page.keyboard.press("Enter", delay=self.args.key_delay_ms)
            self.type_physical("redox")
            before = self.sample(label + "-credentials-entered")["frames"]
            submitted = time.monotonic()
            self.page.keyboard.press("Enter", delay=self.args.key_delay_ms)
            self.page.wait_for_function("n=>window.redoxDemo.diagnostics().resources.display.frames>n",
                                        arg=before, timeout=self.args.command_timeout * 1000)
            # The profile emits this only from the authenticated interactive
            # Orbterm child after initializing readline. The serial channel
            # observes it; it never starts that shell or executes its workload.
            output = self.read_graphical_file(GRAPHICAL_SHELL_READY_FILE, GRAPHICAL_SHELL_READY,
                                             self.args.command_timeout, label + "-interactive-shell-ready")
            require(output.replace("\r", "").splitlines() == [GRAPHICAL_SHELL_READY],
                    "Authenticated graphical shell readiness output differs from UID 0 marker")
            self.evidence.setdefault("graphicalShellReadiness", []).append({"label": label,
                "path": GRAPHICAL_SHELL_READY_FILE, "output": output,
                "enterToObservedReadinessMs": (time.monotonic() - submitted) * 1000})
            self.capture(label + "-login-submitted")
            self.retain_input(label + "-login")

    def read_graphical_file(self, path, marker, timeout, label):
        deadline = time.monotonic() + timeout
        reads = []
        self.evidence.setdefault("serialObservations", []).append({"label": label, "path": path,
            "transport": "read-only guest base64 in fresh token/status record; raw asynchronous diagnostics retained", "reads": reads})
        while time.monotonic() < deadline:
            prefix = "GRAPHICAL_FILE_BYTES:" + secrets.token_hex(12) + ":"
            command = (f"if test -f {shlex.quote(path)}; then bytes=$(/bin/base64 --wrap=0 {shlex.quote(path)}); "
                       f"s=$?; printf '{prefix}%s:%s\\n' \"$s\" \"$bytes\"; fi")
            result = self.run(command,
                              timeout=max(1, min(self.args.command_timeout, deadline - time.monotonic())))
            raw = successful(result, "independent serial file observation")
            record = {"hostMonotonic": time.monotonic(), "command": command, **result}
            reads.append(record)
            # Kernel/driver diagnostics share the UART but are not file bytes.
            # Keep every raw byte above and in the serial artifact; never erase
            # warnings or accept a loosened match on the actual decoded file.
            payloads = [line[len(prefix):] for line in raw.replace("\r", "").splitlines() if line.startswith(prefix)]
            require(len(payloads) <= 1, f"{label}: duplicate independent file observation record")
            if not payloads:
                self.page.wait_for_timeout(min(500, max(0, deadline - time.monotonic()) * 1000))
                continue
            status, encoded = payloads[0].split(":", 1)
            require(status == "0", f"{label}: guest file encoding failed with status {status}")
            output = base64.b64decode(encoded, validate=True).decode("utf-8")
            record["fileOutput"] = output
            lines = output.replace("\r", "").splitlines()
            completions = [line for line in lines if line.startswith(marker.rsplit(":", 1)[0] + ":")]
            if completions:
                require(completions == [marker], f"{label}: real graphical process failed or duplicated completion: {completions}")
                return output
            self.page.wait_for_timeout(min(500, max(0, deadline - time.monotonic()) * 1000))
        raise AssertionError(f"{label}: graphical completion file absent/incomplete after {timeout}s; cannot establish authenticated orbterm focus or keyboard command completion; serial did not execute the graphical command")

    def keyboard_command(self, body, path, marker, label, timeout):
        # The image supplies cat, not tee. Shell redirection preserves the real
        # output for independent serial observation; cat displays those exact
        # guest-produced bytes in orbterm after the command completes.
        destination = shlex.quote(path)
        command = BASH + " -c " + shlex.quote("{ " + body + "; } > " + destination +
                                             " 2>&1; /bin/cat " + destination)
        self.focus()
        before = self.sample(label + "-before")
        self.type_physical(command)
        submitted = time.monotonic()
        self.page.keyboard.press("Enter", delay=self.args.key_delay_ms)
        self.evidence["graphicalRuns"].append({"label": label, "command": command, "file": path,
            "transport": "trusted browser physical key events -> display.js PS/2 ring -> Orbital -> orbterm -> bash", "serialRole": "read-only observer"})
        output = self.read_graphical_file(path, marker, timeout, label)
        self.page.wait_for_function("n=>window.redoxDemo.diagnostics().resources.display.frames>n",
                                    arg=before["frames"], timeout=self.args.command_timeout * 1000)
        self.evidence.setdefault("interactionLatency", []).append({"label": label,
            "enterToIndependentSerialCompletionAndFrameMs": (time.monotonic() - submitted) * 1000,
            "caveat": "Includes command execution and serial polling; not pure PS/2 transport latency"})
        after = self.sample(label + "-after")
        require(after["queueOverflows"] == 0, "Graphical command overflowed the PS/2 input ring")
        self.capture(label)
        self.retain_input(label)
        self.retain(label)
        return output

    def nonce(self, label):
        token = secrets.token_hex(12)
        nonce = secrets.randbelow(10**8) + 1
        expression = f"let n = {nonce}; in n * 7 + 13"
        path = "/tmp/graphical-snix-" + token
        marker = "GRAPHICAL_SNIX_EXIT:" + token + ":0"
        begin = "GRAPHICAL_SNIX_BEGIN:" + token
        # Bash's readonly UID comes from getuid(); userutils/id is not installed
        # in this minimal image. This still asserts the actual authenticated UID.
        body = (f"printf '{begin}\\n'; printf '%s\\n' \"$UID\"; /bin/snix eval --expr {shlex.quote(expression)}; "
                f"s=$?; printf 'GRAPHICAL_SNIX_EXIT:{token}:%s\\n' \"$s\"")
        with self.phase(label + "-keyboard-snix"):
            output = self.keyboard_command(body, path, marker, label, self.args.command_timeout)
            lines = output.replace("\r", "").splitlines()
            require(lines == [begin, "0", str(nonce * 7 + 13), marker],
                    f"Graphical root Snix output differs from selected nonce/exit: {output!r}")
            self.evidence.setdefault("nonceProofs", []).append({"label": label, "expression": expression,
                "expected": nonce * 7 + 13, "file": path, "output": output, "uid": 0})
        return path

    def demo(self):
        token = secrets.token_hex(12)
        path = "/tmp/graphical-demo-" + token
        marker = "GRAPHICAL_DEMO_EXIT:" + token + ":0"
        body = f"{BASH} /etc/browser-demo/run.sh all; s=$?; printf 'GRAPHICAL_DEMO_EXIT:{token}:%s\\n' \"$s\""
        with self.phase("graphical-mandatory-demo"):
            output = self.keyboard_command(body, path, marker, "mandatory-demo", self.args.fixture_timeout)
            require(output.replace("\r", "").splitlines().count(marker) == 1, "Graphical demo exit was not exactly zero once")
            self.evidence["graphicalFixtures"] = assert_fixtures(output, self.evidence["manifest"]["fixtures"])
            self.evidence["graphicalDemoOutput"] = output
            self.measured_resources("mandatory-demo-resources")

    def pointer_wheel(self, label):
        with self.phase(label + "-pointer-wheel"):
            self.focus()
            box = self.canvas.bounding_box()
            require(box and box["width"] > 0 and box["height"] > 0, "Actual graphical surface has no pointer target")
            before = self.sample(label + "-before-pointer")
            x, y = box["x"] + box["width"] / 2, box["y"] + box["height"] / 2
            self.page.mouse.move(x, y)
            self.page.mouse.move(x + box["width"] / 32, y + box["height"] / 32, steps=4)
            self.page.mouse.move(x, y, steps=4)
            self.page.mouse.wheel(0, 120)
            self.page.mouse.wheel(0, -120)
            self.page.mouse.down(button="left")
            started = time.monotonic()
            self.page.wait_for_function("""old => {
              const d=window.redoxDemo.diagnostics().resources.display;
              return d.consumedInputs.pointer>old.pointer && d.consumedInputs.wheel>=old.wheel+2
                && d.consumedInputs.button>old.button && d.queuedInputs===0;
            }""", arg=before["consumedInputs"], timeout=self.args.command_timeout * 1000)
            held = self.sample(label + "-pointer-consumed")
            require(held["heldButtons"] == [0], "Browser did not retain the real held left button")
            self.page.locator("#diagnostics").focus()
            self.page.wait_for_function("""previous => {
              const d=window.redoxDemo.diagnostics().resources.display;
              return d.heldButtons.length===0 && d.releaseRequested>previous
                && d.releaseRequested===d.releaseAcknowledged && d.queuedInputs===0;
            }""", arg=held["releaseRequested"], timeout=self.args.command_timeout * 1000)
            self.page.mouse.up(button="left")
            after = self.measured_resources(label + "-pointer-released")
            require((after["width"], after["height"]) == (before["width"], before["height"]),
                    "Browser pointer activity changed the guest display mode")
            self.evidence.setdefault("pointerProofs", []).append({"label": label,
                "consumerBefore": before["consumedInputs"], "consumerAfter": after["consumedInputs"],
                "consumerAndBlurReleaseMs": (time.monotonic() - started) * 1000,
                "releaseAcknowledged": after["releaseAcknowledged"], "manualSurfaceReviewRequired": True})
            self.capture(label + "-pointer-wheel")
            self.retain_input(label + "-pointer-wheel")

    def hold_modifiers(self, label):
        self.focus()
        for key in ("ShiftLeft", "ControlLeft", "AltLeft"):
            self.page.keyboard.down(key)
        self.page.wait_for_function("""() => {
          const d=window.redoxDemo.diagnostics().resources.display;
          return d && Array.isArray(d.heldKeys) && [42,29,56].every(k=>d.heldKeys.includes(k));
        }""", timeout=self.args.command_timeout * 1000)
        self.sample(label + "-held")

    def release_browser_modifiers(self):
        for key in ("AltLeft", "ControlLeft", "ShiftLeft"):
            self.page.keyboard.up(key)

    def focus_release(self, label):
        with self.phase(label + "-focus-modifier-release"):
            self.hold_modifiers(label)
            held = self.sample(label + "-before-blur")
            self.page.locator("#diagnostics").focus()
            self.page.wait_for_function("""previous => {
              const d=window.redoxDemo.diagnostics().resources.display;
              return d && d.heldKeys?.length===0 && d.heldButtons?.length===0 && d.queuedInputs===0
                && d.releaseRequested>previous && d.releaseAcknowledged===d.releaseRequested;
            }""", arg=held["releaseRequested"], timeout=self.args.command_timeout * 1000)
            self.sample(label + "-consumer-released")
            self.release_browser_modifiers()
            self.focus()
            self.retain_input(label + "-blur-release")
        # Exact lower-case physical input, Snix punctuation and zero exit prove
        # Shift/Ctrl/Alt did not remain stuck in the guest after browser blur.
        self.nonce(label + "-after-focus-release")

    def worker_ids(self, label):
        metrics = self.resources(label)
        return {target["targetId"] for target in metrics["cdpTargets"]
                if target["type"] in ("worker", "shared_worker")
                and "/playground/evaluator-worker.js" not in target.get("url", "")}

    def reset_graphical(self, cycle, mutation):
        label = f"reset-{cycle}"
        with self.phase(label):
            old_id = self.page.evaluate("window.redoxDemo.sessionId")
            old_workers = self.worker_ids(label + "-before")
            self.hold_modifiers(label)
            self.retain_input(label + "-held-before-destruction")
            self.retain(label + "-before")
            self.call("reset")
            self.release_browser_modifiers()
            self.page.wait_for_function("window.redoxDemo.state==='ready'", timeout=self.args.boot_timeout * 1000)
            new_id = self.page.evaluate("window.redoxDemo.sessionId")
            require(new_id and new_id != old_id and new_id not in self.evidence["sessions"], "Graphical reset reused a guest session")
            self.evidence["sessions"].append(new_id)
            require(not old_workers.intersection(self.worker_ids(label + "-after")), "Old graphical workers survived reset")
            successful(self.run(f"test ! -e {mutation}"), "reset must discard keyboard-created guest mutation")
            self.evidence["lifecycle"].append({"operation": "reset", "old": old_id, "new": new_id, "oldWorkers": sorted(old_workers), "mutationAbsent": mutation})
            self.display_ready(label)
            self.login(label)
            return self.nonce(label + "-fresh-keyboard")

    def stop_graphical(self, label):
        with self.phase(label):
            self.hold_modifiers(label)
            self.retain_input(label + "-held-before-stop")
            self.capture(label + "-before")
            self.retain(label + "-before")
            self.stopped()  # Common serial/cache/frame/command/CDP-worker quiescence assertions.
            self.release_browser_modifiers()
            self.frame = self.canvas = None
            self.evidence["lifecycle"].append({"operation": "stop", "commonWorkerQuiescence": True})
            self.retain(label + "-stopped")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("site", help="built graphical browser-site deployment tree")
    parser.add_argument("--chromium", required=True, help="real Chromium executable")
    parser.add_argument("--output", default="graphical-browser-evidence")
    parser.add_argument("--prefix", default="/redox-preview/")
    parser.add_argument("--boot-timeout", type=int, default=600)
    parser.add_argument("--command-timeout", type=int, default=120)
    parser.add_argument("--fixture-timeout", type=int, default=900)
    parser.add_argument("--cycles", type=int, default=2, help="bounded reset/stop/relaunch repetitions")
    parser.add_argument("--quiescence-ms", type=int, default=1000)
    parser.add_argument("--key-delay-ms", type=int, default=25, help="physical key hold time; no paste or serial command injection")
    parser.add_argument("--no-sandbox", action="store_true", help="only for a disposable runner without Chromium sandbox support")
    args = parser.parse_args()
    require(all(getattr(args, name) > 0 for name in ("boot_timeout", "command_timeout", "fixture_timeout", "cycles", "quiescence_ms", "key_delay_ms")), "All deadlines, repetitions and input delays must be positive")
    from playwright.sync_api import sync_playwright
    with server(args.site, port=0, prefix=args.prefix) as http:
        threading.Thread(target=http.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{http.server_port}/{args.prefix.strip('/')}/"
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(executable_path=args.chromium, headless=True,
                args=["--no-sandbox"] if args.no_sandbox else [])
            h = None
            try:
                h = GraphicalHarness(args, browser, base)
                h.open()
                h.selected_machine()
                h.boot("cold")
                h.display_ready("cold")
                h.login("cold")
                mutation = h.nonce("cold-keyboard")
                h.demo()
                h.focus_release("cold")
                h.pointer_wheel("cold")
                for cycle in range(args.cycles):
                    mutation = h.reset_graphical(cycle, mutation)
                    h.stop_graphical(f"stop-{cycle}")
                    h.boot("cold")
                    h.display_ready(f"relaunch-{cycle}")
                    successful(h.run(f"test ! -e {mutation}"), "relaunch must discard keyboard-created guest mutation")
                    h.login(f"relaunch-{cycle}")
                    mutation = h.nonce(f"relaunch-{cycle}-fresh-keyboard")
                    h.focus_release(f"relaunch-{cycle}")
                    h.pointer_wheel(f"relaunch-{cycle}")
                h.stop_graphical("final-stop")
                h.evidence["success"] = True
            except Exception as error:
                if h is not None:
                    h.evidence["failure"] = str(error)
                raise
            finally:
                try:
                    if h is not None:
                        # Retain serial before destroying even a failed display.
                        for action in (lambda: h.retain("final-before-disposal"),
                                       lambda: h.capture("final"),
                                       lambda: h.retain_input("final"),
                                       lambda: h.call("stop")):
                            try:
                                action()
                            except Exception as error:
                                h.evidence.setdefault("cleanupErrors", []).append(str(error))
                        try:
                            h.retain("final")
                        finally:
                            h.context.close()
                finally:
                    try:
                        browser.close()
                    finally:
                        http.shutdown()


if __name__ == "__main__":
    main()
