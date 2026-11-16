const cache = new Map();
const CACHE_LIMIT = 256 * 1024 * 1024;
let cachedBytes = 0;
let transferredBytes = 0;

export const READY_MARKER = "REDOX_BROWSER_DEMO_READY:v1:shell=1:snix=1:initial=1";

export function canonicalJSON(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
  if (value !== null && typeof value === "object") {
    return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonicalJSON(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

export async function sha256(bytes) {
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))]
    .map(byte => byte.toString(16).padStart(2, "0")).join("");
}

export function assetURL(asset, base) {
  const url = new URL(asset.url, base);
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) {
    throw new Error(`Unsupported artifact URL: ${url.href}`);
  }
  return url.href;
}

function validateIdentity(asset, name) {
  if (!asset || typeof asset.url !== "string" || !/^[a-f0-9]{64}$/.test(asset.sha256)
      || !Number.isSafeInteger(asset.size) || asset.size < 0 || asset.size > 0xffffffff) {
    throw new Error(`Invalid immutable artifact identity: ${name}`);
  }
}

export async function verifiedAsset(asset, base, { signal, onProgress, name = asset?.url } = {}) {
  validateIdentity(asset, name);
  signal?.throwIfAborted();
  const key = `${asset.sha256}:${asset.size}`;
  const cached = cache.get(key);
  if (cached) {
    cache.delete(key);
    cache.set(key, cached);
    onProgress?.({ name, received: asset.size, size: asset.size, cached: true });
    return cached;
  }
  const response = await fetch(assetURL(asset, base), { signal, cache: "force-cache", credentials: "same-origin" });
  if (!response.ok) throw new Error(`${name}: HTTP ${response.status}`);
  const bytes = new Uint8Array(asset.size);
  let offset = 0;
  const reader = response.body?.getReader();
  if (!reader) throw new Error(`${name}: response has no byte stream`);
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      if (offset + value.byteLength > bytes.byteLength) throw new Error(`${name}: oversized artifact`);
      bytes.set(value, offset);
      offset += value.byteLength;
      transferredBytes += value.byteLength;
      onProgress?.({ name, received: offset, size: bytes.byteLength, cached: false });
    }
  } catch (error) {
    await reader.cancel().catch(() => {});
    throw error;
  } finally {
    reader.releaseLock();
  }
  if (offset !== asset.size) throw new Error(`${name}: truncated artifact (${offset}/${asset.size})`);
  if (await sha256(bytes) !== asset.sha256) throw new Error(`${name}: SHA-256 mismatch`);
  signal?.throwIfAborted();
  if (bytes.byteLength <= CACHE_LIMIT) {
    while (cachedBytes + bytes.byteLength > CACHE_LIMIT && cache.size) {
      const oldest = cache.keys().next().value;
      cachedBytes -= cache.get(oldest).byteLength;
      cache.delete(oldest);
    }
    const existing = cache.get(key);
    if (!existing) {
      cache.set(key, bytes);
      cachedBytes += bytes.byteLength;
    }
  }
  return bytes;
}

export async function loadManifest(url, { signal } = {}) {
  let current = new URL(url, location.href).href;
  let pinned = null;
  let expectedRevision = null;
  for (let redirects = 0; redirects < 3; redirects += 1) {
    let bytes;
    if (pinned) bytes = await verifiedAsset(pinned, current, { signal, name: "revision manifest" });
    else {
      const response = await fetch(current, { signal, cache: "no-store", credentials: "same-origin" });
      if (!response.ok) throw new Error(`Manifest unavailable: HTTP ${response.status} (${current})`);
      const declared = Number(response.headers.get("content-length"));
      if (declared > 4 * 1024 * 1024) throw new Error("Manifest exceeds 4 MiB");
      bytes = new Uint8Array(await response.arrayBuffer());
      if (bytes.byteLength > 4 * 1024 * 1024) throw new Error("Manifest exceeds 4 MiB");
    }
    let manifest;
    try { manifest = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)); }
    catch (error) { throw new Error(`Invalid manifest JSON: ${error.message}`); }
    if (manifest.schemaVersion !== 1) throw new Error(`Unsupported manifest schema: ${manifest.schemaVersion}`);
    if (manifest.manifest) {
      validateIdentity(manifest.manifest, "revision manifest");
      if (!/^[a-f0-9]{64}$/.test(manifest.revision)) throw new Error("Channel has no immutable bundle revision");
      expectedRevision = manifest.revision;
      pinned = { ...manifest.manifest, url: assetURL(manifest.manifest, current) };
      current = pinned.url;
      continue;
    }
    if (!/^[a-f0-9]{64}$/.test(manifest.revision) || typeof manifest.sourceRevision !== "string"
        || !/^[a-f0-9]{64}$/.test(manifest.runtimeRevision)) throw new Error("Manifest has no complete release/source/runtime identities");
    if (expectedRevision && expectedRevision !== manifest.revision) throw new Error("Channel/release revision mismatch");
    const { revision, ...contract } = manifest;
    if (await sha256(new TextEncoder().encode(canonicalJSON(contract))) !== revision) throw new Error("Bundle revision hash mismatch");
    const runtimeKeys = ["schemaVersion", "sourceRevision", "target", "machine", "machineHash", "assets",
      "fixtures", "engineIdentity", "engineFeatures", "firmwareFiles", "cacheTransport", "cacheIdentity", "guestIdentity"];
    const runtime = Object.fromEntries(runtimeKeys.filter(key => Object.hasOwn(manifest, key)).map(key => [key, manifest[key]]));
    if (await sha256(new TextEncoder().encode(canonicalJSON(runtime))) !== manifest.runtimeRevision) throw new Error("Runtime revision hash mismatch");
    if (manifest.target !== "x86_64-unknown-redox") throw new Error(`Wrong guest target: ${manifest.target}`);
    if (!manifest.machine || !Array.isArray(manifest.machine.args) || !Number.isInteger(manifest.machine.ramMiB)) {
      throw new Error("Manifest has no complete machine contract");
    }
    if (manifest.machine.ramMiB < 1 || manifest.machine.ramMiB > 2047
        || manifest.machine.ram !== `${manifest.machine.ramMiB}M`) {
      throw new Error("Pinned QEMU-WASM requires 1..2047 MiB and a matching ram value in MiB");
    }
    const machineHash = await sha256(new TextEncoder().encode(canonicalJSON(manifest.machine)));
    if (machineHash !== manifest.machineHash) throw new Error("Machine contract hash mismatch");
    for (const role of ["engine", "wasm", "worker", "firmware", "disk", "efi"]) {
      validateIdentity(manifest.assets?.[role], role);
    }
    return { manifest, url: current, hash: await sha256(bytes) };
  }
  throw new Error("Manifest pointer chain is too long");
}

export async function requireCapabilities() {
  if (window.redoxIsolationReady) await window.redoxIsolationReady;
  const missing = [];
  if (!window.isSecureContext) missing.push("HTTPS or localhost");
  if (!window.crossOriginIsolated) missing.push("cross-origin isolation (COOP: same-origin; COEP: require-corp)");
  if (typeof SharedArrayBuffer === "undefined") missing.push("SharedArrayBuffer");
  if (typeof WebAssembly === "undefined") missing.push("WebAssembly");
  if (!crypto.subtle) missing.push("Web Crypto SHA-256");
  if (typeof DecompressionStream === "undefined") missing.push("DecompressionStream for gzip guest disks");
  if (missing.length) throw new Error(`Live Redox requires ${missing.join(", ")}. Use the documented isolated server or the recording.`);
  try {
    new WebAssembly.Memory({ initial: 1, maximum: 1, shared: true });
  } catch (error) {
    throw new Error(`Threaded WebAssembly memory is unavailable: ${error.message}`);
  }
}

export function assetMetrics() {
  return { verifiedCacheBytes: cachedBytes, verifiedCacheEntries: cache.size, decodedTransferredBytes: transferredBytes, cacheLimitBytes: CACHE_LIMIT };
}
