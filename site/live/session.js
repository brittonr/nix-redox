import { READY_MARKER, assetMetrics, assetURL, canonicalJSON, loadManifest, requireCapabilities, sha256, verifiedAsset } from "./assets.js";

const TRANSCRIPT_LIMIT = 1024 * 1024;
const MAX_COMMAND_BYTES = 65536;
const BASH = "/nix/system/profile/bin/bash";
// A base64 command spawns /bin/base64; at the measured ~1.3 KB/s guest serial
// input rate, that process costs about as much as 1 KiB of extra command text.
const DECODER_COST_BYTES = 1024;
const token = () => [...crypto.getRandomValues(new Uint8Array(16))].map(byte => byte.toString(16).padStart(2, "0")).join("");
const aborted = () => new DOMException("VM session ended", "AbortError");

function commandBytes(text) {
  const bytes = new TextEncoder().encode(text);
  if (bytes.byteLength > MAX_COMMAND_BYTES) throw new Error("Guest command exceeds 64 KiB");
  return bytes;
}

function base64(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

// One printable-ASCII Bash word carrying arbitrary bytes, or null when base64
// and its decoder process are cheaper to send. NUL keeps the base64 behavior.
function quotedWord(bytes) {
  if (bytes.includes(0)) return null;
  let word = "$'";
  for (const byte of bytes) {
    if (byte === 0x27 || byte === 0x5c) word += `\\${String.fromCharCode(byte)}`;
    else if (byte >= 0x20 && byte < 0x7f) word += String.fromCharCode(byte);
    else word += `\\x${byte.toString(16).padStart(2, "0")}`;
  }
  word += "'";
  return word.length <= Math.ceil(bytes.byteLength / 3) * 4 + DECODER_COST_BYTES ? word : null;
}

export class RedoxSession extends EventTarget {
  constructor(container) {
    super();
    this.container = container;
    this.state = "stopped";
    this.sessionId = null;
    this.transcript = "";
    this.manifest = null;
    this.manifestHash = null;
    this.manifestURL = null;
    this.error = null;
    this.phase = "stopped";
    this.timings = {};
    this._subscribers = new Set();
    this._epoch = 0;
    this._pending = new Set();
    this._commandTail = Promise.resolve();
    this._metrics = {};
    this._options = {};
  }

  get signal() { return this._controller?.signal; }

  _state(value, phase = value) {
    this.state = value;
    this.phase = phase;
    const now = performance.now();
    this.timings[phase] ??= now;
    this.timings[value] ??= now;
    this.dispatchEvent(new CustomEvent("state", { detail: { state: value, phase, sessionId: this.sessionId } }));
  }

  _progress(detail) { this.dispatchEvent(new CustomEvent("progress", { detail })); }

  _assert(epoch) {
    if (epoch !== this._epoch || this.signal?.aborted) throw aborted();
  }

  async boot(options = {}) {
    if (["loading", "starting", "ready"].includes(this.state)) throw new Error("Stop the current VM before starting another");
    this._options = { mode: "cold", diskBackend: "preload", ...options };
    this.error = null;
    this.resumeError = null;
    this.transcript = "";
    this.timings = { requested: performance.now() };
    try {
      return await this._start(this._options);
    } catch (error) {
      if (error.name === "AbortError") throw error;
      if (this._options.mode === "snapshot" && this._options.coldFallback !== false) {
        this.resumeError = String(error.message ?? error);
        this._progress({ phase: "cold-fallback", error: this.resumeError });
        this._dispose();
        try { return await this._start({ ...this._options, mode: "cold" }); }
        catch (coldError) { this._fail(coldError); throw coldError; }
      }
      this._fail(error);
      throw error;
    }
  }

  async _start(options) {
    this._dispose();
    const epoch = ++this._epoch;
    this.sessionId = token();
    this._controller = new AbortController();
    this.mode = options.mode;
    this._loadingTimer = setTimeout(() => this._controller?.abort(new Error("Timed out loading verified VM assets")), options.assetTimeoutMs ?? 300000);
    this._commandTail = Promise.resolve();
    this._metrics = {};
    this._state("loading", "capabilities");
    await requireCapabilities();
    this._assert(epoch);
    this._state("loading", "manifest");
    const selectedURL = options.manifestUrl ?? new URL("../manifest.json", import.meta.url).href;
    const loaded = await loadManifest(selectedURL, { signal: this.signal });
    this._assert(epoch);
    this.manifest = loaded.manifest;
    this.manifestHash = loaded.hash;
    this.manifestURL = loaded.url;
    const features = this.manifest.engineFeatures ?? [];
    if (options.diskBackend === "lazy" && (!this.manifest.assets.diskChunks || !features.includes("browser-chunk"))) {
      throw new Error("This engine revision does not contain the browser-chunk block driver. Select the preload disk or a verified patched engine.");
    }
    if (this.manifest.machine.display?.backend === "redox-browser-rgba-v1" && !features.includes("browser-display")) {
      throw new Error("The graphical machine requires a separately built engine containing the browser display backend");
    }
    if (options.mode === "snapshot" && options.diskBackend !== "preload") throw new Error("Snapshot restore requires its captured preload disk");
    this._state("loading", "assets");
    const data = {};
    const fetchRole = async (role, asset, base = loaded.url) => {
      data[role] = await verifiedAsset(asset, base, { signal: this.signal, name: role, onProgress: progress => {
        if (epoch === this._epoch) this._progress({ phase: "download", ...progress });
      } });
    };
    const roles = ["engine", "wasm", "worker", "firmware", "efi", "xterm", "xtermCss", "pty"];
    if (options.diskBackend === "preload" && options.mode === "cold") roles.push("disk");
    // The machine firmware is already a primary role; every other pack file
    // downloads concurrently with it instead of one request at a time afterwards.
    const pack = { [this.manifest.machine.firmware.file]: "firmware" };
    const packFiles = [];
    for (const [filename, asset] of Object.entries(this.manifest.firmwareFiles ?? {})) {
      if (!/^[A-Za-z0-9][A-Za-z0-9_,.-]*$/.test(filename)) throw new Error(`Unsafe firmware pack filename: ${filename}`);
      if (filename === this.manifest.machine.firmware.file) continue;
      pack[filename] = `pack:${filename}`;
      packFiles.push([pack[filename], typeof asset === "string" ? this.manifest.assets[asset] : asset]);
    }
    await Promise.all([
      ...roles.map(role => fetchRole(role, this.manifest.assets[role])),
      ...packFiles.map(([role, asset]) => fetchRole(role, asset)),
    ]);
    let snapshot = null;
    if (options.mode === "snapshot") {
      if (!this.manifest.snapshot) throw new Error("No compatible snapshot is published for this exact revision");
      const metadataBytes = await verifiedAsset(this.manifest.snapshot, loaded.url, { signal: this.signal, name: "snapshot manifest" });
      snapshot = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(metadataBytes));
      if (snapshot.schemaVersion !== 1 || snapshot.kind !== "redox-browser-snapshot"
          || snapshot.machineHash !== this.manifest.machineHash
          || canonicalJSON(snapshot.machine) !== canonicalJSON(this.manifest.machine)
          || snapshot.bindings?.sourceRevision !== this.manifest.sourceRevision
          || snapshot.bindings?.runtimeRevision !== this.manifest.runtimeRevision
          || canonicalJSON(snapshot.bindings.runtimeAssets) !== canonicalJSON(this.manifest.assets)
          || canonicalJSON(snapshot.bindings.firmwareFiles ?? {}) !== canonicalJSON(this.manifest.firmwareFiles ?? {})
          || canonicalJSON(snapshot.firmwareState) !== canonicalJSON(this.manifest.machine.firmware)
          || await sha256(new TextEncoder().encode(canonicalJSON(snapshot.bindings))) !== snapshot.compatibilityHash) {
        throw new Error("Snapshot engine/machine/CPU/RAM/disk/firmware/revision binding mismatch");
      }
      const base = assetURL(this.manifest.snapshot, loaded.url);
      for (const [role, artifact] of Object.entries(snapshot.artifacts)) {
        if (typeof artifact.file !== "string" || !/^[A-Za-z0-9_,.-]+(?:\/[A-Za-z0-9_,.-]+)*$/.test(artifact.file)
             || artifact.file.split("/").some(segment => segment === "." || segment === "..")) {
          throw new Error(`Unsafe snapshot artifact: ${role}`);
        }
        await fetchRole(`snapshot:${role}`, { ...artifact, url: artifact.file }, base);
      }
      for (const role of ["state", "disk", "firmware", "efi"]) {
        if (!data[`snapshot:${role}`] || canonicalJSON(snapshot.bindings.captureAssets[role]) !== canonicalJSON(snapshot.artifacts[role])) {
          throw new Error(`Snapshot ${role} capture boundary mismatch`);
        }
      }
      if (typeof snapshot.handshake?.resumeInput !== "string" || typeof snapshot.handshake?.resumedMarker !== "string") {
        throw new Error("Snapshot has no bounded guest resume handshake");
      }
    }
    this._snapshotResumeMarker = snapshot?.handshake.resumedMarker ?? null;
    clearTimeout(this._loadingTimer);
    this._loadingTimer = null;
    this._assert(epoch);
    this.timings.assetsVerified = performance.now();
    this._state("starting", options.mode === "snapshot" ? "restoring" : "firmware");
    const frame = document.createElement("iframe");
    frame.title = "Live Redox VM terminal";
    frame.className = "vm-frame";
    frame.setAttribute("allow", "cross-origin-isolated; fullscreen");
    this._frame = frame;
    const start = new Promise((resolve, reject) => {
      this._startResolve = resolve;
      this._startReject = reject;
      this._bootTimer = setTimeout(() => this._fail(new Error(`Guest ${options.mode === "snapshot" ? "resume" : "boot"} timed out during ${this.phase}; download diagnostics for the raw serial log`)), options.bootTimeoutMs ?? 300000);
    });
    start.catch(() => {});
    this._messageListener = event => {
      if (epoch !== this._epoch || event.source !== frame.contentWindow || event.origin !== location.origin
          || event.data?.channel !== "redox-vm" || event.data.sessionId !== this.sessionId) return;
      const message = event.data;
      if (message.type === "frame-ready") {
        const assets = {};
        const transfers = [];
        for (const [role, bytes] of Object.entries(data)) {
          // Large uncached captures transfer ownership; small immutable downloads
          // retain a pristine parent copy for Reset and warm-cache measurements.
          assets[role] = bytes.byteLength > 256 * 1024 * 1024 ? bytes : bytes.slice();
          transfers.push(assets[role].buffer);
        }
        frame.contentWindow.postMessage({ channel: "redox-vm", type: "initialize", sessionId: this.sessionId,
          config: { manifest: this.manifest, manifestURL: this.manifestURL, assets, pack, snapshot,
            mode: options.mode, diskBackend: options.diskBackend } }, location.origin, transfers);
      } else if (message.type === "serial") this._serial(message.text, options);
      else if (message.type === "failure") this._fail(new Error(message.error));
      else if (message.type === "phase") {
        this.phase = message.phase;
        this.timings[message.phase] ??= performance.now();
        this._progress({ phase: message.phase });
      } else if (message.type === "metrics") this._metrics = message.metrics;
    };
    window.addEventListener("message", this._messageListener);
    frame.src = new URL(`./frame.html?session=${this.sessionId}`, import.meta.url).href;
    this.container.replaceChildren(frame);
    return start;
  }

  _serial(text, options) {
    if (typeof text !== "string") return;
    this.transcript = (this.transcript + text).slice(-TRANSCRIPT_LIMIT);
    for (const subscriber of this._subscribers) subscriber(text);
    this.dispatchEvent(new CustomEvent("serial", { detail: text }));
    const normalized = this.transcript.replace(/\r/g, "");
    const marker = options.mode === "snapshot" ? this._snapshotResumeMarker : READY_MARKER;
    // Only the guest protocol, never worker or firmware activity, establishes readiness.
    if (this.state === "starting" && marker && normalized.split("\n").includes(marker)) this._ready();
  }

  _ready() {
    clearTimeout(this._bootTimer);
    this._bootTimer = null;
    this._state("ready");
    this._startResolve?.();
    this._startResolve = null;
    this._startReject = null;
  }

  _fail(error) {
    this.error = String(error.message ?? error);
    const reject = this._startReject;
    this._startResolve = null;
    this._startReject = null;
    this._dispose(error);
    this._state("failed", this.phase);
    reject?.(error);
    this.dispatchEvent(new CustomEvent("failure", { detail: this.error }));
  }

  _dispose(reason = aborted()) {
    this._controller?.abort(reason);
    clearTimeout(this._bootTimer);
    clearTimeout(this._loadingTimer);
    this._loadingTimer = null;
    this._bootTimer = null;
    for (const reject of this._pending) reject(reason);
    this._pending.clear();
    this._lastRuntimeMetrics = this._metrics;
    this._metrics = {};
    if (this._messageListener) window.removeEventListener("message", this._messageListener);
    this._messageListener = null;
    // Destroying the owning document disposes the Emscripten main thread and all
    // dedicated pthread workers, rather than depending on private PThread APIs.
    this._frame?.remove();
    this._frame = null;
    this._startReject?.(reason);
    this._startResolve = null;
    this._startReject = null;
  }

  async stop() {
    ++this._epoch;
    this._dispose();
    this._state("stopped");
  }

  async reset() {
    const options = { ...this._options };
    await this.stop();
    return this.boot(options);
  }

  send(text) {
    if (!["starting", "ready"].includes(this.state) || !this._frame) throw new Error("No active guest serial channel");
    this._frame.contentWindow.postMessage({ channel: "redox-vm", type: "input", sessionId: this.sessionId, text }, location.origin);
  }

  setInputEnabled(enabled) {
    this._frame?.contentWindow.postMessage({ channel: "redox-vm", type: "input-enabled", sessionId: this.sessionId, enabled: Boolean(enabled) }, location.origin);
  }

  subscribe(callback) {
    this._subscribers.add(callback);
    return () => this._subscribers.delete(callback);
  }

  run(source, { timeoutMs = 120000 } = {}) {
    const epoch = this._epoch;
    const execute = async () => {
      this._assert(epoch);
      if (this.state !== "ready") throw new Error("Wait for the actual Redox shell before running a command");
      const commandToken = token();
      const bytes = commandBytes(source);
      const word = quotedWord(bytes);
      const begin = `REDOX_BROWSER_BEGIN:${commandToken}`;
      const end = `REDOX_BROWSER_DEMO_COMMAND:${commandToken}:`;
      return new Promise((resolve, reject) => {
        let buffer = "";
        let timer;
        const finish = (error, result) => {
          clearTimeout(timer);
          unsubscribe();
          this._pending.delete(cancel);
          error ? reject(error) : resolve(result);
        };
        const cancel = error => finish(error);
        const unsubscribe = this.subscribe(text => {
          if (epoch !== this._epoch) return;
          buffer = (buffer + text).replace(/\r/g, "");
          const start = buffer.indexOf(`\n${begin}\n`);
          if (start === -1) {
            if (buffer.length > TRANSCRIPT_LIMIT) buffer = buffer.slice(-TRANSCRIPT_LIMIT);
            return;
          }
          const content = buffer.slice(start + begin.length + 2);
          const completion = new RegExp(`(?:^|\\n)${end}([0-9]+)(?:\\n|$)`).exec(content);
          if (completion) finish(null, { status: Number(completion[1]), output: content.slice(0, completion.index) });
          else if (content.length > TRANSCRIPT_LIMIT) finish(new Error("Guest command output exceeded the 1 MiB bound"));
        });
        this._pending.add(cancel);
        timer = setTimeout(() => {
          const error = new Error(`Guest command timed out after ${timeoutMs} ms`);
          finish(error);
          this._fail(error);
        }, timeoutMs);
        try {
          // Script text belongs in argv, not stdin: receivers and other guest
          // commands must retain the serial console. A quoted word runs in a
          // subshell of one fresh Bash, with no decoder or second shell process;
          // the base64 sentinel preserves trailing newlines through command
          // substitution. Either way the final newline ends the output line.
          const execute = word
            ? `${BASH} -c 'src=$1; shift; (eval "unset -v src; $src"); s=$?; printf "\\n"; exit "$s"' ${BASH} ${word}`
            : `${BASH} -o pipefail -c 'decoded=$(printf "%s" "${base64(bytes)}" | /bin/base64 -d; s=$?; printf "."; exit "$s") || exit $?; decoded=\${decoded%.}; ${BASH} -c "$decoded"; s=$?; printf "\\n"; exit "$s"'`;
          this.send(`printf '\\n${begin}\\n'; browser_command ${commandToken} ${execute}\n`);
        } catch (error) { finish(error); }
      });
    };
    const result = this._commandTail.then(execute);
    this._commandTail = result.catch(() => {});
    return result;
  }

  async executeExpression(source) {
    const bytes = commandBytes(source);
    const word = quotedWord(bytes);
    const file = `/playground/v1/.browser-expression-${token()}.nix`;
    // The source is only data in a quoted word or base64, including quotes,
    // newlines and shell syntax. A failed write or decode is the result: Snix
    // never evaluates an empty or partial file.
    const write = word ? `printf '%s' ${word} > ${file}` : `printf '%s' '${base64(bytes)}' | /bin/base64 -d > ${file}`;
    return this.run(`${write}\nstatus=$?\nif [ "$status" -eq 0 ]; then /bin/snix eval --file ${file}; status=$?; fi\n/bin/rm -f ${file}\nexit "$status"`);
  }

  diagnostics() {
    return { schemaVersion: 1, state: this.state, phase: this.phase, error: this.error, resumeError: this.resumeError,
      revision: this.manifest?.revision, manifestHash: this.manifestHash, machineHash: this.manifest?.machineHash,
      manifest: this.manifest, manifestURL: this.manifestURL, sessionId: this.sessionId, mode: this.mode,
      timings: { ...this.timings }, transcript: this.transcript, resources: { ...assetMetrics(), ...this._metrics,
        trackedFrames: this._frame ? 1 : 0, pendingCommands: this._pending.size, transcriptLimitCharacters: TRANSCRIPT_LIMIT },
      lastObservedRuntime: this._lastRuntimeMetrics ?? null,
      browser: navigator.userAgent, hardwareConcurrency: navigator.hardwareConcurrency, deviceMemoryGiB: navigator.deviceMemory ?? null };
  }
}
