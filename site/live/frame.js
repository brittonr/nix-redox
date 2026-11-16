import { sha256 } from "./assets.js";
import { attachChunkDisk, loadChunkDisk } from "./chunk-disk.js";
import { createGraphicalPanel } from "./display.js";

const sessionId = new URL(location.href).searchParams.get("session");
const lifetime = new AbortController();
const urls = [];
let initialized = false;
let module;
let master;
let terminal;
let display;
let disposeTerminalFit;
let disk;
let config;
let serialBuffer = "";
let serialTimer;
let metricsTimer;
let resumeTimer;
let resumeSent = false;
let engineTranscript = "";
let failed = false;
const decoder = new TextDecoder();

const post = (type, fields = {}) => parent.postMessage({ channel: "redox-vm", sessionId, type, ...fields }, location.origin);
const fail = error => {
  if (lifetime.signal.aborted || failed) return;
  failed = true;
  clearTimeout(serialTimer);
  serialTimer = null;
  if (serialBuffer) {
    post("serial", { text: serialBuffer });
    serialBuffer = "";
  }
  post("failure", { error: String(error?.message ?? error) });
};

function blobURL(bytes, type, prefix = "") {
  const url = URL.createObjectURL(new Blob([prefix, bytes], { type }));
  urls.push(url);
  return url;
}

async function script(bytes) {
  const element = document.createElement("script");
  element.src = blobURL(bytes, "text/javascript");
  await new Promise((resolve, reject) => {
    element.onload = resolve;
    element.onerror = () => reject(new Error("Verified terminal library failed to load"));
    document.head.append(element);
  });
}

function send(text) {
  if (!master || lifetime.signal.aborted) throw new Error("Guest serial channel is not initialized");
  master.ldisc.writeFromLower(text);
}

function serial(data) {
  const text = typeof data === "string" ? data : decoder.decode(data, { stream: true });
  serialBuffer += text;
  engineTranscript = (engineTranscript + text).slice(-65536);
  if (!serialTimer) serialTimer = setTimeout(() => {
    serialTimer = null;
    post("serial", { text: serialBuffer });
    serialBuffer = "";
  }, 16);
  if (config?.snapshot && !resumeSent && engineTranscript.includes("vm_state_notify running 1")) {
    resumeSent = true;
    send(config.snapshot.handshake.resumeInput);
  }
}

function fitTerminalWidth() {
  const element = terminal.element;
  const screen = element.querySelector(".xterm-screen");
  const viewport = element.querySelector(".xterm-viewport");
  if (!screen || !viewport) throw new Error("Pinned terminal layout is unavailable");
  if (lifetime.signal.aborted) return;
  let frame = 0;
  const fit = () => {
    frame = 0;
    if (lifetime.signal.aborted) return;
    // Use the rendered cell pitch and public column count, not xterm's private
    // renderer fields. Keep the font readable; only the serial grid changes.
    const cellWidth = screen.getBoundingClientRect().width / terminal.cols;
    const style = getComputedStyle(element);
    const scrollbar = viewport.offsetWidth - viewport.clientWidth;
    const width = element.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight) - scrollbar;
    if (cellWidth <= 0 || width <= 0) return; // Hidden frames fit when shown.
    const cols = Math.max(2, Math.floor(width / cellWidth));
    if (cols !== terminal.cols) terminal.resize(cols, terminal.rows);
  };
  const schedule = () => {
    if (!frame && !lifetime.signal.aborted) frame = requestAnimationFrame(fit);
  };
  const observer = new ResizeObserver(schedule);
  observer.observe(element);
  observer.observe(screen);
  window.addEventListener("resize", schedule, { signal: lifetime.signal });
  document.fonts?.addEventListener("loadingdone", schedule, { signal: lifetime.signal });
  schedule();
  return () => {
    observer.disconnect();
    cancelAnimationFrame(frame);
    window.removeEventListener("resize", schedule);
    document.fonts?.removeEventListener("loadingdone", schedule);
  };
}

async function rawDisk(bytes, identity) {
  const expectedSize = identity.logicalSize ?? identity.size;
  const expectedHash = identity.rawSha256 ?? identity.sha256;
  let raw;
  if (identity.encoding === "gzip") {
    if (!Number.isSafeInteger(expectedSize) || expectedSize <= 0 || expectedSize > 0xffffffff) throw new Error("Invalid logical disk size");
    raw = new Uint8Array(expectedSize);
    const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip"));
    const reader = stream.getReader();
    let offset = 0;
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        if (offset + value.byteLength > raw.byteLength) throw new Error("Expanded disk exceeds its declared logical size");
        raw.set(value, offset);
        offset += value.byteLength;
      }
      if (offset !== raw.byteLength) throw new Error(`Expanded disk is truncated (${offset}/${raw.byteLength})`);
    } catch (error) {
      await reader.cancel().catch(() => {});
      throw error;
    } finally { reader.releaseLock(); }
  } else raw = bytes;
  if (raw.byteLength !== expectedSize || await sha256(raw) !== expectedHash) throw new Error("Expanded disk identity mismatch");
  return raw;
}

function argumentsFor(machine) {
  const substitutions = { pack: "/pack", disk: "/disk/redox.raw", ram: machine.ram };
  return machine.args.map(argument => argument.replace(/\{([A-Za-z]+)\}/g, (_, name) => {
    if (!(name in substitutions)) throw new Error(`Unknown machine argument placeholder: ${name}`);
    return substitutions[name];
  }));
}

function withoutPreload(args) {
  const result = [];
  let driveFound = false;
  let deviceFound = false;
  for (let index = 0; index < args.length; index += 1) {
    if (args[index] === "-drive" && args[index + 1]?.includes("file=/disk/redox.raw,")) {
      driveFound = true;
      index += 1;
    } else if (args[index] === "-device" && args[index + 1] === "virtio-blk-pci,drive=redox") {
      deviceFound = true;
      index += 1;
    } else result.push(args[index]);
  }
  if (!driveFound || !deviceFound) throw new Error("Machine does not have the declared replaceable preload block attachment");
  return result;
}

async function initialize(value) {
  config = value;
  const assets = config.assets;
  const { machine } = config.manifest;
  post("phase", { phase: "terminal" });
  const style = document.createElement("link");
  style.rel = "stylesheet";
  style.href = blobURL(assets.xtermCss, "text/css");
  await new Promise((resolve, reject) => {
    style.onload = resolve;
    style.onerror = () => reject(new Error("Verified terminal stylesheet failed to load"));
    document.head.append(style);
  });
  await script(assets.xterm);
  await script(assets.pty);
  if (typeof window.Terminal !== "function" || typeof window.openpty !== "function") throw new Error("Pinned terminal/PTY ABI is unavailable");
  terminal = new window.Terminal({ cols: 100, rows: 30, scrollback: 3000, convertEol: false, fontSize: 14, cursorBlink: true });
  terminal.open(document.getElementById("terminal"));
  const pty = window.openpty();
  master = pty.master;
  master.onWrite(([data, callback]) => {
    serial(data);
    terminal.write(data, callback);
  });
  // QEMU owns a raw PTY. Edit user input with the pinned canonical discipline
  // separately: local echo is display-only, never guest serial evidence, and
  // encoded guided commands bypass this editor.
  const input = window.openpty();
  let echo = [];
  let completeEcho;
  input.master.onWrite(([data, callback]) => { echo.push(data); completeEcho = callback; });
  input.slave.onReadable(() => {
    const bytes = input.slave.read();
    send(bytes.length ? bytes : [4]);
  });
  const signalBytes = { SIGINT: 3, SIGQUIT: 28, SIGTSTP: 26 };
  input.slave.onSignal(signal => {
    const byte = signalBytes[signal];
    if (byte !== undefined) send([byte]);
  });
  terminal.onData(data => {
    input.master.ldisc.writeFromLower(data.replace(/\r\n?/g, "\n"));
    // Queue all local echo before the next asynchronous guest output, batching
    // large pastes instead of allocating an xterm write for every character.
    while (completeEcho) { const next = completeEcho; completeEcho = null; next(); }
    if (echo.length) {
      let bytes = echo[0];
      if (echo.length > 1) {
        bytes = new Uint8Array(echo.reduce((size, chunk) => size + chunk.length, 0));
        let offset = 0;
        for (const chunk of echo) { bytes.set(chunk, offset); offset += chunk.length; }
      }
      terminal.write(bytes);
      echo = [];
    }
  });
  terminal.onResize(({ rows, cols }) => master.notifyResize(rows, cols));
  master.notifyResize(terminal.rows, terminal.cols);
  disposeTerminalFit = fitTerminalWidth();
  terminal.attachCustomKeyEventHandler(event => {
    if (event.type === "keydown" && event.key.toLowerCase() === "c" && (event.ctrlKey || event.metaKey) && terminal.hasSelection()) {
      navigator.clipboard?.writeText(terminal.getSelection()).catch(() => {});
      return false;
    }
    return true;
  });
  let raw = null;
  if (config.diskBackend === "preload") {
    post("phase", { phase: "expanding-disk" });
    const identity = config.snapshot ? config.snapshot.artifacts.disk : config.manifest.assets.disk;
    raw = await rawDisk(config.snapshot ? assets["snapshot:disk"] : assets.disk, identity);
    delete assets.disk;
    delete assets["snapshot:disk"];
  } else {
    const identity = config.manifest.assets.diskChunks;
    disk = await loadChunkDisk({ ...identity, url: new URL(identity.url, config.manifestURL).href }, { signal: lifetime.signal });
  }
  if (machine.display?.backend === "redox-browser-rgba-v1") {
    display = createGraphicalPanel({ signal: lifetime.signal });
    document.getElementById("display").append(display.element);
  }
  // Pthreads re-import this verified blob without the main thread's locateFile.
  // Emscripten still eagerly resolves its WASM filename from import.meta.url.
  const engineSourceURL = new URL(config.manifest.assets.engine.url, config.manifestURL).href;
  const engineURL = blobURL(assets.engine, "text/javascript", `import.meta.url = ${JSON.stringify(engineSourceURL)};\n`);
  const workerURL = blobURL(assets.worker, "text/javascript");
  const wasmURL = blobURL(assets.wasm, "application/wasm");
  let args = argumentsFor(machine);
  const options = {
    ...display?.moduleOptions,
    pty: pty.slave,
    arguments: args,
    wasmBinary: assets.wasm,
    mainScriptUrlOrBlob: engineURL,
    locateFile: file => {
      if (file.endsWith(".wasm")) return wasmURL;
      if (file.endsWith(".worker.js")) return workerURL;
      throw new Error(`Engine requested undeclared artifact: ${file}`);
    },
    onAbort: reason => fail(new Error(`WASM engine aborted: ${reason}`)),
    onExit: status => fail(new Error(`Emulator exited with status ${status}`)),
    quit: (status, error) => {
      // Successful main return can retain the active Emscripten VM loop.
      if (status !== 0) fail(new Error(`Emulator exited with status ${status}`));
      throw error;
    },
    preRun: [mod => {
      module = mod;
      mod.FS.mkdirTree("/pack");
      mod.FS.mkdirTree("/disk");
      for (const [filename, role] of Object.entries(config.pack)) mod.FS.writeFile(`/pack/${filename}`, assets[role], { canOwn: true });
      if (config.snapshot) {
        mod.FS.writeFile(`/pack/${machine.firmware.file}`, assets["snapshot:firmware"], { canOwn: true });
        mod.FS.writeFile("/pack/vm.state", assets["snapshot:state"], { canOwn: true });
      }
      if (raw) {
        mod.FS.writeFile("/disk/redox.raw", raw, { canOwn: true });
        raw = null;
      }
    }],
  };
  if (disk) {
    // Root-disk I/O can strand the guest after a rejected write. Fail its
    // owning session promptly, including pending commands, rather than waiting
    // for an unrelated guest-command deadline.
    const write = disk.write.bind(disk);
    disk.write = (offset, source) => write(offset, source).catch(error => {
      fail(error);
      throw error;
    });
    args = [...withoutPreload(args), ...attachChunkDisk(options, disk)];
  }
  if (config.snapshot) {
    args = ["-incoming", "file:/pack/vm.state", "-trace", "enable=vm_state_notify", ...args];
    resumeTimer = setTimeout(() => fail(new Error("Snapshot never announced a running machine/resume handshake")), config.snapshot.handshake.timeoutMs ?? 120000);
  }
  options.arguments = args;
  post("phase", { phase: config.snapshot ? "migration" : "firmware" });
  const factory = (await import(engineURL)).default;
  if (typeof factory !== "function") throw new Error("Verified engine has no Emscripten factory");
  // This factory already uses PROXY_TO_PTHREAD. It belongs on this document's
  // main thread, not inside another Worker with a second filesystem/terminal.
  Promise.resolve(factory(options)).then(mod => {
    module = mod;
    terminal.focus();
  }).catch(fail);
  metricsTimer = setInterval(() => {
    if (config.snapshot && engineTranscript.replace(/\r/g, "").split("\n").includes(config.snapshot.handshake.resumedMarker)) clearTimeout(resumeTimer);
    post("metrics", { metrics: {
      wasmMemoryBytes: module?.HEAPU8?.buffer?.byteLength ?? null,
      guestRamMiB: machine.ramMiB,
      logicalDiskBytes: config.snapshot ? config.snapshot.artifacts.disk.size : config.manifest.assets.disk.logicalSize,
      retainedRuntimeAssetBytes: Object.values(assets).reduce((sum, bytes) => sum + bytes.byteLength, 0),
      workerCount: null,
      workerCountNote: "Private Emscripten worker bookkeeping is not a supported runtime API; browser smoke observes CDP worker targets.",
      ...(disk ? { chunkDisk: disk.stats } : {}),
      ...(display ? { display: display.metrics() } : {}),
    } });
  }, 1000);
}

window.addEventListener("message", event => {
  if (event.source !== parent || event.origin !== location.origin || event.data?.channel !== "redox-vm" || event.data.sessionId !== sessionId) return;
  if (event.data.type === "initialize" && !initialized) {
    initialized = true;
    initialize(event.data.config).catch(fail);
  } else if (event.data.type === "input") {
    try { send(event.data.text); } catch (error) { fail(error); }
  } else if (event.data.type === "input-enabled" && terminal) terminal.options.disableStdin = !event.data.enabled;
});
window.addEventListener("error", event => fail(event.error ?? event.message));
window.addEventListener("unhandledrejection", event => fail(event.reason));
window.addEventListener("pagehide", () => {
  lifetime.abort();
  clearInterval(metricsTimer);
  clearTimeout(resumeTimer);
  clearTimeout(serialTimer);
  disposeTerminalFit?.();
  display?.dispose();
  disk?.close();
  terminal?.dispose();
  for (const url of urls) URL.revokeObjectURL(url);
}, { once: true });
post("frame-ready");
