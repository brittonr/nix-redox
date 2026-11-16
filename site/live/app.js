import { RedoxSession } from "./session.js";
import { createCacheTransport, mountCacheTransport } from "./cache-transport.js";

const $ = selector => document.querySelector(selector);
const session = new RedoxSession($("#guest"));
window.redoxDemo = session;
let busy = false;
let playground;
let transport;
let transportSession;
let serialRefresh;

function report(error) { $("#error").textContent = String(error.message ?? error); }

function controls() {
  const active = ["loading", "starting", "ready"].includes(session.state);
  $("#boot").disabled = active;
  $("#stop").disabled = !active;
  $("#reset").disabled = session.state === "loading" || session.state === "starting";
  $("#mode").disabled = active;
  $("#disk-backend").disabled = active;
  for (const id of ["evaluate", "build", "package", "fixtures"]) $("#" + id).disabled = session.state !== "ready" || busy;
  $("#state").textContent = `${session.state}: ${session.phase}`;
  playground?.refreshGuestState();
}

async function action(operation) {
  if (busy) return;
  const ownId = session.sessionId;
  busy = true;
  $("#error").textContent = "";
  controls();
  session.setInputEnabled(false);
  try {
    const result = await operation();
    if (session.sessionId !== ownId) return;
    if (result) {
      $("#command-output").textContent = `Actual Redox process exit status: ${result.status}\n${result.output}`;
      if (result.status !== 0) throw new Error(`Guest command exited with status ${result.status}; see its real output and serial diagnostics`);
    }
  } catch (error) { if (session.sessionId === ownId) report(error); }
  finally {
    if (session.sessionId === ownId) {
      busy = false;
      if (session.state === "ready") session.setInputEnabled(true);
      controls();
    }
  }
}

function bootOptions() {
  const manifestUrl = new URL(location.href).searchParams.get("manifest");
  return { mode: $("#mode").value, diskBackend: $("#disk-backend").value, ...(manifestUrl ? { manifestUrl } : {}) };
}

$("#boot").addEventListener("click", async () => {
  $("#error").textContent = "";
  $("#command-output").textContent = "";
  try { await session.boot(bootOptions()); } catch (error) { if (error.name !== "AbortError") report(error); }
});
$("#stop").addEventListener("click", () => session.stop());
$("#reset").addEventListener("click", async () => {
  $("#error").textContent = "";
  $("#command-output").textContent = "";
  try { await session.reset(); } catch (error) { if (error.name !== "AbortError") report(error); }
});
$("#evaluate").addEventListener("click", () => action(() => session.executeExpression($("#expression").value)));
$("#build").addEventListener("click", () => action(() => {
  const input = $("#build-input").value;
  if (!/^[A-Za-z0-9_-]{1,128}$/.test(input)) throw new Error("Build input must contain 1–128 letters, digits, underscores or hyphens");
  return session.run(`/nix/system/profile/bin/bash /etc/browser-demo/run.sh build ${input}`, { timeoutMs: 300000 });
}));
$("#package").addEventListener("click", () => action(() => session.run(
  "test ! -e /nix/var/snix/profiles/default/bin/rg || exit 1\n" +
  "/bin/snix install ripgrep --recursive --cache-path /nix/cache || exit $?\n" +
  "/nix/var/snix/profiles/default/bin/rg --fixed-strings --line-regexp REDOX_BROWSER_RIPGREP_SAMPLE /etc/browser-demo/sample.txt\n" +
  "status=$?\n/bin/snix remove ripgrep || exit $?\nexit \"$status\"", { timeoutMs: 300000 })));
$("#fixtures").addEventListener("click", () => action(() => session.run(
  "/nix/system/profile/bin/bash /etc/browser-demo/run.sh all", { timeoutMs: 900000 })));

$("#diagnostics").addEventListener("click", () => {
  const url = URL.createObjectURL(new Blob([JSON.stringify(session.diagnostics(), null, 2)], { type: "application/json" }));
  const link = document.createElement("a");
  link.href = url;
  link.download = `redox-${session.sessionId ?? "stopped"}-diagnostics.json`;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
});

function setupTransport() {
  if (transportSession === session.sessionId) return;
  transport?.dispose();
  transport = null;
  transportSession = session.sessionId;
  $("#cache-ui").replaceChildren();
  $("#downloads").hidden = !session.manifest?.cacheTransport;
  if (!session.manifest?.cacheTransport) return;
  const manifest = { ...session.manifest, cacheTransport: { ...session.manifest.cacheTransport,
    url: new URL(session.manifest.cacheTransport.url, session.manifestURL).href } };
  const ownId = session.sessionId;
  const ownSignal = session.signal;
  const requireOwnSession = () => {
    if (ownSignal.aborted || session.sessionId !== ownId) throw new DOMException("VM session ended", "AbortError");
  };
  const generation = {
    signal: ownSignal,
    send(text) { requireOwnSession(); return session.send(text); },
    run(source, options) { requireOwnSession(); return session.run(source, options); },
    subscribe(callback) {
      requireOwnSession();
      const unsubscribe = session.subscribe(text => {
        if (!ownSignal.aborted && session.sessionId === ownId) callback(text);
      });
      ownSignal.addEventListener("abort", unsubscribe, { once: true });
      return () => { ownSignal.removeEventListener("abort", unsubscribe); unsubscribe(); };
    },
  };
  transport = createCacheTransport({ session: generation, manifest, onProgress: progress => {
    if (session.sessionId !== ownId) return;
    if (progress.phase === "serial-owned") { busy = true; session.setInputEnabled(false); }
    if (progress.phase === "serial-released") { busy = false; session.setInputEnabled(true); }
    if (progress.phase === "reset-required") {
      busy = true;
      session.setInputEnabled(false);
      report(new Error("Cache receiver did not release the serial channel. Reset the VM before sending more input."));
    }
    $("#progress").textContent = `Package transport: ${progress.phase}`;
    controls();
  } });
  mountCacheTransport($("#cache-ui"), transport);
}

session.addEventListener("state", () => {
  controls();
  if (session.manifest) $("#identity").textContent = `Revision ${session.manifest.revision} · ${session.manifest.target} · machine ${session.manifest.machineHash} · ${session.manifest.machine.ramMiB} MiB guest RAM`;
  if (session.state === "ready") setupTransport();
  if (["failed", "stopped"].includes(session.state)) {
    transport?.dispose();
    transport = null;
    transportSession = null;
    busy = false;
    controls();
  }
});
session.addEventListener("failure", event => report(event.detail));
session.addEventListener("progress", event => {
  const progress = event.detail;
  $("#progress").textContent = progress.phase === "download"
    ? `${progress.name}: ${(progress.received / 1048576).toFixed(1)} / ${(progress.size / 1048576).toFixed(1)} MiB${progress.cached ? " (verified cache)" : ""}`
    : `${progress.phase}${progress.error ? `: ${progress.error}` : ""}`;
});
session.addEventListener("serial", () => {
  if (!serialRefresh) serialRefresh = setTimeout(() => {
    serialRefresh = null;
    $("#serial").textContent = session.transcript;
  }, 100);
});

try {
  const { mountPlayground } = await import("../playground/index.js");
  playground = mountPlayground($("#playground"), {
    executeExpression: async source => {
      const result = await session.executeExpression(source);
      return { exitCode: result.status, stdout: result.output };
    },
    guestReady: () => session.state === "ready",
  });
} catch (error) {
  $("#playground").textContent = `The independent WASM evaluator is unavailable in this build: ${error.message}. This does not substitute for Redox guest execution.`;
}
window.addEventListener("pagehide", () => {
  clearTimeout(serialRefresh);
  playground?.dispose();
  transport?.dispose();
  session.stop();
}, { once: true });
controls();
