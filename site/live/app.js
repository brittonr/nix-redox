import "../chrome.js";
import { RedoxSession } from "./session.js";
import { createCacheTransport, mountCacheTransport } from "./cache-transport.js";

const $ = selector => document.querySelector(selector);

// Workbench chrome is independent of the guest/session and serial input paths.
const toolTabs = $("#tool-tabs");
const tabs = [...toolTabs.querySelectorAll('[role="tab"]')];
const selectTool = (tab, updateHash = false) => {
  for (const candidate of tabs) {
    const selected = candidate === tab;
    candidate.setAttribute("aria-selected", selected);
    candidate.tabIndex = selected ? 0 : -1;
    const panel = document.getElementById(candidate.getAttribute("aria-controls"));
    panel.classList.toggle("is-active", selected);
    panel.hidden = !selected;
  }
  $("#guest-result").hidden = tab.getAttribute("aria-controls") === "playground";
  if (updateHash) history.replaceState(history.state, "", "#" + tab.getAttribute("aria-controls"));
};
toolTabs.addEventListener("click", event => {
  const tab = event.target.closest('[role="tab"]');
  if (tab) selectTool(tab, true);
});
toolTabs.addEventListener("keydown", event => {
  const index = tabs.indexOf(event.target);
  if (index < 0) return;
  const last = tabs.length - 1;
  const next = {
    ArrowRight: index === last ? 0 : index + 1,
    ArrowLeft: index === 0 ? last : index - 1,
    Home: 0,
    End: last,
  }[event.key];
  if (next === undefined) return;
  event.preventDefault();
  selectTool(tabs[next], true);
  tabs[next].focus();
});
const syncToolHash = () => {
  const tab = tabs.find(candidate => location.hash === "#" + candidate.getAttribute("aria-controls"));
  if (tab) selectTool(tab);
  if (location.hash === "#raw-diagnostics") $("#raw-diagnostics").open = true;
};
selectTool(tabs[0]);
window.addEventListener("hashchange", syncToolHash);
syncToolHash();
// Guest-tool links choose a task, but a new session still needs an explicit
// Boot. Keep those controls visible instead of landing below them in a panel.
// The independent WASM evaluator and raw-diagnostic anchors keep native scroll.
if (["#shell", "#nix", "#packages"].includes(location.hash)) {
  const showSession = () => requestAnimationFrame(() => $("#machine").scrollIntoView({ block: "start", behavior: "instant" }));
  if (document.readyState === "complete") showSession();
  else window.addEventListener("load", showSession, { once: true });
}

const session = new RedoxSession($("#guest"));
window.redoxDemo = session;
let currentAction = null;
let inputLock = "";
let lastAction = "";
let actionClock = null;
let bootClock = null;
let elapsedTimer;
let playground;
let transport;
let transportSession;
let displayedSession;
let serialRefresh;
let diagnosticUrl;
let diagnosticTimer;
let lifecycleRequest = 0;
let disposed = false;
const downloads = new Map();
const identityPlaceholder = $("#identity").textContent;
const busy = () => Boolean(currentAction || inputLock);
const seconds = milliseconds => `${(Math.max(0, milliseconds) / 1000).toFixed(1)} s`;
const endedSession = () => new DOMException("VM session ended", "AbortError");

function report(error) {
  $("#error").textContent = String(error.message ?? error);
  controls();
}

function renderElapsed() {
  const now = performance.now();
  const parts = [];
  if (bootClock) parts.push(`Boot ${bootClock.ended == null ? "elapsed" : bootClock.outcome}: ${seconds((bootClock.ended ?? now) - bootClock.started)}`);
  if (actionClock) parts.push(`${actionClock.label} ${actionClock.ended == null ? "elapsed" : "duration"}: ${seconds((actionClock.ended ?? now) - actionClock.started)}`);
  $("#elapsed").textContent = parts.join(" · ");
}

function updateClock() {
  const running = !disposed && ((bootClock && bootClock.ended == null) || (actionClock && actionClock.ended == null));
  if (running && !elapsedTimer) elapsedTimer = setInterval(renderElapsed, 250);
  if (!running && elapsedTimer) { clearInterval(elapsedTimer); elapsedTimer = null; }
  renderElapsed();
}

function controls() {
  const active = ["loading", "starting", "ready"].includes(session.state);
  const ready = session.state === "ready";
  const locked = busy();
  $("#boot").disabled = active;
  $("#stop").disabled = !active;
  $("#reset").disabled = session.state === "loading" || session.state === "starting";
  for (const id of ["evaluate", "build", "package", "fixtures", "run-command"]) $("#" + id).disabled = !ready || locked;
  $("#transport-controls").disabled = !ready || Boolean(inputLock) || Boolean(currentAction && currentAction.source !== "transport");
  const state = $("#state");
  let terminal;
  if (ready && inputLock) {
    state.textContent = `Input blocked. ${inputLock} Reset or Stop the VM.`;
    terminal = "Reset required";
  } else if (ready && currentAction) {
    state.textContent = `Busy: ${currentAction.label}. Console input is paused until it finishes.`;
    terminal = `Busy / ${currentAction.label}`;
  } else if (ready) {
    state.textContent = "Ready. Type in the console or use the tools.";
    terminal = "Ready / input enabled";
  } else if (session.state === "loading") {
    state.textContent = `Loading (${session.phase}). Downloading and verifying the VM.`;
    terminal = "Loading / wait for Ready";
  } else if (session.state === "starting") {
    state.textContent = `Booting (${session.phase}). First boot can take a few minutes.`;
    terminal = "Booting / input not ready";
  } else if (session.state === "failed") {
    state.textContent = "Error: the VM failed. See below, or press Boot to try again.";
    terminal = "Error / VM unavailable";
  } else {
    state.textContent = "Stopped. Press Boot to start the guest.";
    terminal = "Stopped / press Boot";
  }
  $(".machine-status").dataset.state = session.state === "failed" || inputLock ? "failed" : $("#error").textContent ? "error" : ready && locked ? "busy" : session.state;
  $("#terminal-state").textContent = terminal;
  $("#action-status").textContent = currentAction ? `${currentAction.label}… ${currentAction.wait}` : inputLock || lastAction || "";
  playground?.refreshGuestState();
}

async function action(label, operation, { source = "guided", display = true, rethrow = false, wait = "Guest execution may take a while; the elapsed clock measures real time." } = {}) {
  if (session.state !== "ready" || busy()) {
    const error = new Error(busy() ? "Another action owns the guest serial channel. Wait for it to finish." : "Wait for the actual Redox shell to become Ready.");
    if (rethrow) throw error;
    report(error);
    return;
  }
  const owner = { label, source, wait, sessionId: session.sessionId, signal: session.signal, started: performance.now() };
  const ownsSession = () => currentAction === owner && session.sessionId === owner.sessionId && !owner.signal.aborted;
  currentAction = owner;
  actionClock = owner;
  lastAction = "";
  $("#error").textContent = "";
  if (display) $("#command-output").textContent = `${label} is running. Waiting for actual guest output and exit status…\nLive output is also visible in the terminal and serial diagnostics.`;
  controls();
  updateClock();
  session.setInputEnabled(false);
  try {
    const result = await operation();
    if (!ownsSession()) throw endedSession();
    if (result && display) {
      $("#command-output").textContent = `${label}\nActual Redox process exit status: ${result.status}\nElapsed: ${seconds(performance.now() - owner.started)}\n\n${result.output || "(No output)"}`;
    }
    lastAction = `${label} finished in ${seconds(performance.now() - owner.started)}${result && Number.isInteger(result.status) ? ` with actual exit status ${result.status}` : ""}.`;
    if (result && Number.isInteger(result.status) && result.status !== 0) {
      const error = new Error(`Guest command exited with status ${result.status}; see its real output and serial diagnostics`);
      // The playground consumes nonzero exit codes as real guest results.
      if (source === "playground") { report(error); return result; }
      throw error;
    }
    return result;
  } catch (error) {
    if (ownsSession()) {
      lastAction = `${label} did not complete successfully after ${seconds(performance.now() - owner.started)}. ${error.message ?? error}`;
      if (display && !$("#command-output").textContent.includes("Actual Redox process exit status:")) $("#command-output").textContent = `${label}: no completed guest result.\n${error.message ?? error}\nSee the terminal and bounded serial diagnostics for partial output.`;
      report(error);
    }
    if (rethrow) throw error;
  } finally {
    if (ownsSession()) {
      owner.ended = performance.now();
      currentAction = null;
      if (session.state === "ready" && !inputLock) session.setInputEnabled(true);
      if (source === "transport") $("#progress").textContent = "";
      controls();
      updateClock();
    }
  }
}

function bootOptions() {
  const manifestUrl = new URL(location.href).searchParams.get("manifest");
  return manifestUrl ? { manifestUrl } : {};
}

async function start(reset = false) {
  const request = ++lifecycleRequest;
  $("#error").textContent = "";
  try { await (reset ? session.reset() : session.boot(bootOptions())); }
  catch (error) { if (request === lifecycleRequest && error.name !== "AbortError") report(error); }
}
$("#boot").addEventListener("click", () => start());
$("#stop").addEventListener("click", () => { ++lifecycleRequest; session.stop(); });
$("#reset").addEventListener("click", () => start(true));
$("#evaluate").addEventListener("click", () => action("Evaluating the Nix expression", () => session.executeExpression($("#expression").value)));
$("#build").addEventListener("click", () => action("Building a fresh output", () => {
  const input = $("#build-input").value;
  if (!/^[A-Za-z0-9_-]{1,128}$/.test(input)) throw new Error("Build input must contain 1–128 letters, digits, underscores or hyphens");
  return session.run(`/nix/system/profile/bin/bash /etc/browser-demo/run.sh build ${input}`, { timeoutMs: 300000 });
}, { wait: "A fresh guest build can take several minutes (5-minute command timeout)." }));
$("#package").addEventListener("click", () => action("Installing and running bundled ripgrep", () => session.run(
  "test ! -e /nix/var/snix/profiles/default/bin/rg || exit 1\n" +
  "/bin/snix install ripgrep --recursive --cache-path /nix/cache || exit $?\n" +
  "/nix/var/snix/profiles/default/bin/rg --fixed-strings --line-regexp REDOX_BROWSER_RIPGREP_SAMPLE /etc/browser-demo/sample.txt\n" +
  "status=$?\n/bin/snix remove ripgrep || exit $?\nexit \"$status\"", { timeoutMs: 300000 }),
{ wait: "The offline install, sample run and profile removal can take several minutes (5-minute timeout)." }));
$("#fixtures").addEventListener("click", () => action("Running offline install/build/rollback checks", () => session.run(
  "/nix/system/profile/bin/bash /etc/browser-demo/run.sh all", { timeoutMs: 900000 }),
{ wait: "The complete offline checks include builds and can take many minutes (15-minute timeout)." }));
$("#run-command").addEventListener("click", () => action("Running your shell command", () => {
  const command = $("#shell-command").value;
  if (!command.trim()) throw new Error("Enter a shell command before running it.");
  return session.run(command);
}, { wait: "Waiting for the guest shell to exit (2-minute timeout). Avoid commands that need interactive input." }));
for (const [id, command] of [["example-files", "pwd\nls"], ["example-snix", "/bin/snix eval --expr '1 + 1'"]]) {
  $("#" + id).addEventListener("click", () => {
    $("#shell-command").value = command;
    $("#shell-command").focus();
  });
}

$("#diagnostics").addEventListener("click", () => {
  clearTimeout(diagnosticTimer);
  if (diagnosticUrl) URL.revokeObjectURL(diagnosticUrl);
  const url = URL.createObjectURL(new Blob([JSON.stringify(session.diagnostics(), null, 2)], { type: "application/json" }));
  diagnosticUrl = url;
  const link = document.createElement("a");
  link.href = url;
  link.download = `redox-${session.sessionId ?? "stopped"}-diagnostics.json`;
  link.click();
  diagnosticTimer = setTimeout(() => {
    URL.revokeObjectURL(url);
    diagnosticUrl = null;
    diagnosticTimer = null;
  }, 1000);
});

function setupTransport() {
  if (transportSession === session.sessionId) return;
  transport?.dispose();
  transport = null;
  transportSession = session.sessionId;
  $("#cache-ui").replaceChildren();
  delete $("#cache-ui").dataset.resetRequired;
  $("#downloads").hidden = !session.manifest?.cacheTransport;
  if (!session.manifest?.cacheTransport) return;
  const manifest = { ...session.manifest, cacheTransport: { ...session.manifest.cacheTransport,
    url: new URL(session.manifest.cacheTransport.url, session.manifestURL).href } };
  const ownId = session.sessionId;
  const ownSignal = session.signal;
  const requireOwnSession = () => {
    if (ownSignal.aborted || session.sessionId !== ownId) throw endedSession();
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
  const ownTransport = createCacheTransport({ session: generation, manifest, onProgress: progress => {
    if (ownSignal.aborted || session.sessionId !== ownId) return;
    if (progress.phase === "reset-required") {
      inputLock = "Cache receiver did not release the serial channel.";
      session.setInputEnabled(false);
      report(new Error(`${inputLock} Reset the VM before sending more input.`));
    }
    // The catalog also loads in the background at Ready; only an install the
    // user started reports progress here.
    if (currentAction?.source === "transport") $("#progress").textContent = progress.received != null
      ? `Package ${progress.phase}: ${progress.path} · ${progress.received.toLocaleString()} / ${progress.total.toLocaleString()} bytes`
      : `Package transport ${progress.phase}${progress.message ? `: ${progress.message}` : ""}`;
    controls();
  } });
  transport = ownTransport;
  mountCacheTransport($("#cache-ui"), {
    catalog: () => ownTransport.catalog(),
    install: (name, options) => action(`Transferring and installing ${name}`, () => {
      requireOwnSession();
      return ownTransport.install(name, options);
    }, { source: "transport", display: false, rethrow: true, wait: "Verified package objects are downloaded, transferred over serial and installed; this can take several minutes." }),
    dispose: () => ownTransport.dispose(),
  });
}

function clearGuestResults() {
  $("#command-output").textContent = "No guest command has run in this session.";
  const guestOutput = $('#playground pre[aria-label="Actual Redox guest output"]');
  if (guestOutput) guestOutput.textContent = "";
  clearTimeout(serialRefresh);
  serialRefresh = null;
  $("#serial").textContent = "";
  lastAction = "";
  actionClock = null;
}

session.addEventListener("state", () => {
  const now = performance.now();
  if (session.state === "loading" && displayedSession !== session.sessionId) {
    displayedSession = session.sessionId;
    currentAction = null;
    inputLock = "";
    clearGuestResults();
    downloads.clear();
    $("#download-list").replaceChildren();
    $("#progress").textContent = "Checking browser support and release metadata…";
    $("#identity").textContent = identityPlaceholder;
    bootClock = { started: session.timings.requested ?? now };
  }
  if (session.manifest && session.phase !== "capabilities" && session.phase !== "manifest") $("#identity").textContent = `Revision ${session.manifest.revision} · ${session.manifest.target} · machine ${session.manifest.machineHash} · ${session.manifest.machine.ramMiB} MiB guest RAM`;
  if (["starting", "ready"].includes(session.state)) {
    for (const item of downloads.values()) item.textContent = item.textContent.replace(" · received; verifying", " · verified");
  }
  if (session.state === "ready") {
    if (bootClock && bootClock.ended == null) { bootClock.ended = now; bootClock.outcome = "to guest Ready"; }
    $("#progress").textContent = "";
    setupTransport();
  }
  if (["failed", "stopped"].includes(session.state)) {
    if (bootClock && bootClock.ended == null) { bootClock.ended = now; bootClock.outcome = session.state === "failed" ? "failed after" : "stopped after"; }
    transport?.dispose();
    transport = null;
    transportSession = null;
    $("#cache-ui").replaceChildren();
    $("#downloads").hidden = true;
    currentAction = null;
    inputLock = "";
    clearGuestResults();
    downloads.clear();
    $("#download-list").replaceChildren();
    $("#identity").textContent = identityPlaceholder;
    $("#progress").textContent = session.state === "failed" ? "VM session failed; partial output is in Diagnostics." : "";
    $("#guest").replaceChildren();
    const placeholder = document.createElement("p");
    placeholder.className = "terminal-empty";
    placeholder.textContent = session.state === "failed" ? "The VM failed. See the error above, then press Boot to try again." : "Guest stopped. Press Boot to start again.";
    $("#guest").append(placeholder);
    if (session.state === "stopped") $("#error").textContent = "";
    $("#serial").textContent = session.transcript;
  }
  controls();
  updateClock();
});
session.addEventListener("failure", event => report(event.detail));
session.addEventListener("progress", event => {
  const progress = event.detail;
  if (progress.phase === "download") {
    let item = downloads.get(progress.name);
    if (!item) {
      item = document.createElement("li");
      downloads.set(progress.name, item);
      $("#download-list").append(item);
    }
    item.textContent = `${progress.name}: ${(progress.received / 1048576).toFixed(1)} / ${(progress.size / 1048576).toFixed(1)} MiB · ${progress.cached ? "verified memory cache" : progress.received === progress.size ? "received; verifying" : "downloading"}`;
    $("#progress").textContent = `${progress.cached ? "Reusing verified" : "Downloading"} ${progress.name}: ${(progress.received / 1048576).toFixed(1)} / ${(progress.size / 1048576).toFixed(1)} MiB${!progress.cached && progress.received === progress.size ? " · received; verifying" : ""}`;
  } else {
    $("#progress").textContent = `${progress.phase}${progress.error ? `: ${progress.error}` : ""}${session.state === "starting" ? ". Waiting for the guest to report Ready." : ""}`;
  }
  controls();
});
session.addEventListener("serial", () => {
  if (!serialRefresh) serialRefresh = setTimeout(() => {
    serialRefresh = null;
    $("#serial").textContent = session.transcript;
  }, 100);
});

window.addEventListener("pagehide", () => {
  disposed = true;
  ++lifecycleRequest;
  clearTimeout(serialRefresh);
  clearTimeout(diagnosticTimer);
  if (diagnosticUrl) URL.revokeObjectURL(diagnosticUrl);
  clearInterval(elapsedTimer);
  elapsedTimer = null;
  playground?.dispose();
  playground = null;
  transport?.dispose();
  session.stop();
}, { once: true });
try {
  const { mountPlayground } = await import("../playground/index.js");
  if (!disposed) playground = mountPlayground($("#playground"), {
    executeExpression: async source => {
      const result = await action("Evaluating the playground expression in Redox", () => session.executeExpression(source), { source: "playground", display: false, rethrow: true });
      return { exitCode: result.status, stdout: result.output };
    },
    guestReady: () => session.state === "ready" && !inputLock && (!currentAction || currentAction.source === "playground"),
  });
} catch (error) {
  if (!disposed) $("#playground").textContent = `The independent WASM evaluator is unavailable in this build: ${error.message}. This does not substitute for Redox guest execution.`;
}
controls();
