// Trusted static-release cache delivery. No guest networking or live-image writes.
const PREFIX = '@@SNIX_CACHE_V1@@';
const TARGET = 'x86_64-unknown-redox';
const MAX_DESCRIPTOR = 4 * 1024 * 1024;
const MAX_OBJECT = 128 * 1024 * 1024;
const MAX_TRANSFER = 256 * 1024 * 1024;
const MAX_FILES = 256;
const CHUNK_SIZE = 8192;
const CACHE_NAME = 'snix-verified-cache-v1';
export const CACHE_LIMITS = Object.freeze({ descriptorBytes: MAX_DESCRIPTOR, objectBytes: MAX_OBJECT,
  transferBytes: MAX_TRANSFER, files: MAX_FILES, chunkBytes: CHUNK_SIZE, concurrency: 1 });
const hex = bytes => Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
const id = () => hex(crypto.getRandomValues(new Uint8Array(16)));
const digest = async bytes => hex(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)));
const quote = text => "'" + text.replaceAll("'", "'\\''") + "'";
const abortError = () => new DOMException('Cache transfer cancelled/reset', 'AbortError');
const checkAbort = signal => { if (signal?.aborted) throw signal.reason || abortError(); };
function withAbort(promise, signal) {
  return new Promise((resolve, reject) => {
    const abort = () => { signal.removeEventListener('abort', abort); reject(signal.reason || abortError()); };
    signal.addEventListener('abort', abort, { once: true });
    promise.then(value => { signal.removeEventListener('abort', abort); resolve(value); },
      error => { signal.removeEventListener('abort', abort); reject(error); });
    if (signal.aborted) abort();
  });
}
const validPath = path => typeof path === 'string' && path.length > 0 &&
  !/[%?#:]/.test(path) && !path.includes('\\') && path.split('/').every(p => p && p !== '.' && p !== '..');
const validHash = hash => typeof hash === 'string' && /^[a-f0-9]{64}$/.test(hash);

export function validateDescriptor(value) {
  if (!value || value.version !== 1 || value.target !== TARGET || !value.packages ||
      typeof value.packages !== 'object' || Array.isArray(value.packages)) {
    throw new Error('Unsupported/non-Redox cache transport catalog');
  }
  for (const [name, pkg] of Object.entries(value.packages)) {
    if (!/^[a-zA-Z0-9._+-]{1,128}$/.test(name) || !pkg ||
        !/^\/nix\/store\/[0-9abcdfghijklmnpqrsvwxyz]{32}-[^/]+$/.test(pkg.storePath) ||
        !Array.isArray(pkg.files) || !pkg.files.length || pkg.files.length > MAX_FILES) {
      throw new Error('Invalid curated package/closure');
    }
    let total = 0;
    const paths = new Set();
    for (const file of pkg.files) {
      if (!validPath(file.path) || !validHash(file.sha256) || !Number.isSafeInteger(file.size) ||
          file.size < 0 || file.size > MAX_OBJECT || paths.has(file.path)) {
        throw new Error('Invalid/duplicate immutable cache object');
      }
      paths.add(file.path);
      total += file.size;
    }
    if (total > MAX_TRANSFER || !['packages.json', 'closure.json', 'nix-cache-info'].every(p => paths.has(p))) {
      throw new Error('Incomplete/oversized runtime closure');
    }
  }
  return value;
}

function cacheKey(hash) {
  return new URL(`./__snix_verified_objects/${hash}`, globalThis.location?.href || 'http://localhost/').href;
}

// CacheStorage is an optimization only: every hit is rehashed. Storage-denied
// browsers still use the same verified transfer, and the guest retains objects.
async function getCache(onProgress) {
  if (!globalThis.caches) return null;
  try { return await caches.open(CACHE_NAME); }
  catch (error) { onProgress({ phase: 'storage-unavailable', message: error.message }); return null; }
}

async function trimCache(cache, incomingSize) {
  const entries = [];
  let total = incomingSize;
  for (const key of await cache.keys()) {
    const response = await cache.match(key);
    const size = Number(response?.headers.get('x-snix-size'));
    if (!Number.isSafeInteger(size) || size < 0) { await cache.delete(key); continue; }
    entries.push({ key, size });
    total += size;
  }
  for (const entry of entries) {
    if (total <= MAX_TRANSFER + MAX_DESCRIPTOR) break;
    await cache.delete(entry.key);
    total -= entry.size;
  }
}

async function fetchPinned(file, url, signal, cache, onProgress) {
  checkAbort(signal);
  const key = cacheKey(file.sha256);
  let bytes;
  const cached = cache && await cache.match(key);
  if (cached) {
    bytes = new Uint8Array(await cached.arrayBuffer());
    if (bytes.length === file.size && await digest(bytes) === file.sha256) {
      onProgress({ phase: 'browser-cache-hit', path: file.path, bytes: bytes.length });
      return bytes;
    }
    await cache.delete(key);
  }
  const timeout = AbortSignal.timeout(45000);
  const response = await fetch(url, { signal: AbortSignal.any([signal, timeout]), credentials: 'omit',
    mode: 'cors', cache: 'no-store', redirect: 'error' });
  if (!response.ok || !response.body) throw new Error(`Cache Fetch failed (${response.status}) for ${file.path}`);
  const length = response.headers.get('content-length');
  if (length !== null && !response.headers.get('content-encoding') && Number(length) !== file.size) throw new Error(`Cache length mismatch: ${file.path}`);
  bytes = new Uint8Array(file.size);
  let offset = 0;
  const reader = response.body.getReader();
  try {
    while (true) {
      checkAbort(signal);
      const { done, value } = await reader.read();
      if (done) break;
      if (offset + value.length > bytes.length) throw new Error(`Oversized cache object: ${file.path}`);
      bytes.set(value, offset);
      offset += value.length;
      onProgress({ phase: 'download', path: file.path, received: offset, total: bytes.length });
    }
  } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
  if (offset !== file.size || await digest(bytes) !== file.sha256) throw new Error(`Short/corrupt cache object: ${file.path}`);
  checkAbort(signal);
  if (cache) {
    try {
      await trimCache(cache, bytes.length);
      await cache.put(key, new Response(bytes, { headers: { 'x-snix-size': String(bytes.length) } }));
    } catch (error) { onProgress({ phase: 'storage-unavailable', message: error.message }); }
  }
  return bytes;
}

/**
 * manifest.cacheTransport is pinned by the trusted deployment, never discovered
 * from arbitrary remote metadata: {url,sha256:<lowercase hex>,size:<bytes>}.
 * session is one VM generation: {send,subscribe,run,signal}. run returns
 * Promise<{status,output}>; subscribe returns an unsubscribe function.
 */
export function createCacheTransport({ session, manifest, onProgress = () => {} }) {
  const pin = manifest?.cacheTransport;
  if (!pin || !validHash(pin.sha256) || !Number.isSafeInteger(pin.size) ||
      pin.size <= 0 || pin.size > MAX_DESCRIPTOR || typeof pin.url !== 'string') {
    throw new Error('Release has no valid pinned Redox cache transport descriptor');
  }
  const base = globalThis.location?.href || 'http://localhost/';
  const descriptorURL = new URL(pin.url, base);
  if (!['https:', 'http:'].includes(descriptorURL.protocol)) throw new Error('Cache requires HTTP(S) Fetch');
  const lifetime = new AbortController();
  const liveSignal = AbortSignal.any([lifetime.signal, session.signal].filter(Boolean));
  let busy = false;
  let catalogPromise;
  async function catalog() {
    checkAbort(liveSignal);
    if (!catalogPromise) {
      catalogPromise = (async () => {
        const cache = await getCache(onProgress);
        const bytes = await fetchPinned({ ...pin, path: 'transport.json' }, descriptorURL.href, liveSignal, cache, onProgress);
        const descriptor = validateDescriptor(JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)));
        return { descriptor, bytes, cache };
      })().catch(error => { catalogPromise = null; throw error; });
    }
    return catalogPromise;
  }
  return {
    async catalog() {
      const { descriptor } = await catalog();
      // Metadata only. No package NAR or narinfo is fetched by browsing.
      return Object.entries(descriptor.packages).map(([name, pkg]) => ({ name,
        storePath: pkg.storePath, downloadBytes: pkg.files.reduce((sum, f) => sum + f.size, 0),
        objectCount: pkg.files.length }));
    },
    async install(name, { signal, onCommit = () => {} } = {}) {
      if (busy) throw new Error('Another serial cache transfer owns this VM');
      busy = true;
      let unsubscribe = () => {};
      let command;
      let pending;
      let seq = 0;
      let committed = false;
      let commandSettled = false;
      let receiverFailed = false;
      let requiresReset = false;
      const operationSignal = AbortSignal.any([liveSignal, signal].filter(Boolean));
      const sessionID = id(), requestID = id();
      const started = performance.now();
      let fetchedBytes = 0, sentBytes = 0, guestReusedBytes = 0;
      const rejectPending = error => { if (pending) { const p = pending; pending = null; p.reject(error); } };
      const wait = (expectedSeq, timeoutMs, cancellable = true) => new Promise((resolve, reject) => {
        const abortSignal = cancellable ? operationSignal : liveSignal;
        const abort = () => rejectPending(abortSignal.reason || abortError());
        const timer = setTimeout(() => rejectPending(new Error('Guest cache response timeout')), timeoutMs);
        const clean = () => { clearTimeout(timer); abortSignal.removeEventListener('abort', abort); };
        pending = { seq: expectedSeq, resolve: value => { clean(); resolve(value); }, reject: error => { clean(); reject(error); } };
        abortSignal.addEventListener('abort', abort, { once: true });
        if (abortSignal.aborted) abort();
      });
      const exchange = async (op, extra = {}, timeoutMs = 60000, cancellable = true) => {
        if (cancellable) checkAbort(operationSignal); else checkAbort(liveSignal);
        seq += 1;
        const response = wait(seq, timeoutMs, cancellable);
        // Observe rejection even if send itself fails synchronously.
        response.catch(() => {});
        try { await session.send(JSON.stringify({ v: 1, session: sessionID, request: requestID, seq, op, ...extra }) + '\n'); }
        catch (error) { rejectPending(error); }
        return response;
      };
      let buffer = '';
      try {
        checkAbort(operationSignal);
        const { descriptor, bytes, cache } = await withAbort(catalog(), operationSignal);
        checkAbort(operationSignal);
        const pkg = descriptor.packages[name];
        if (!pkg) throw new Error('Package not in pinned Redox catalog');
        unsubscribe = session.subscribe(text => {
          buffer += text;
          let end;
          while ((end = buffer.indexOf('\n')) !== -1) {
            const line = buffer.slice(0, end).replace(/\r/g, '');
            buffer = buffer.slice(end + 1);
            if (!line.startsWith(PREFIX)) continue; // serial echo and install logs
            let value;
            try { value = JSON.parse(line.slice(PREFIX.length)); } catch { continue; }
            if (value.v !== 1 || value.session !== sessionID || value.request !== requestID) continue;
            if (value.op === 'error') {
              receiverFailed = true;
              rejectPending(new Error(value.detail?.message || 'Guest cache failure'));
              continue;
            }
            if (!pending) continue;
            if (value.seq !== pending.seq) { rejectPending(new Error('Guest cache response sequence mismatch')); continue; }
            const p = pending; pending = null; p.resolve(value);
          }
          if (buffer.length > 8192) buffer = buffer.slice(-8192);
        });
        const ready = wait(0, 30000);
        ready.catch(() => {});
        onProgress({ phase: 'serial-owned', package: name });
        // The session must execute source without consuming the guest console
        // stdin: the foreground receiver owns that stream until it exits.
        command = session.run(`snix browser-cache --session ${sessionID} --request ${requestID} ` +
          `--descriptor-sha256 ${pin.sha256} --descriptor-size ${pin.size} --package ${quote(name)}`, { timeoutMs: 3600000 });
        command.then(result => {
          commandSettled = true;
          if (pending) rejectPending(new Error(`Guest receiver exited before response (status ${result.status})`));
        }, error => { commandSettled = true; rejectPending(error); });
        const greeting = await ready;
        if (greeting.op !== 'ready' || greeting.detail?.chunkSize !== CHUNK_SIZE) throw new Error('Incompatible guest cache receiver');
        async function transfer(file, index, knownBytes) {
          const begin = await exchange('begin', { index });
          if (begin.op === 'have') { guestReusedBytes += file.size; return; }
          if (begin.op !== 'need') throw new Error('Invalid guest object response');
          const data = knownBytes || await fetchPinned(file, new URL(file.path, descriptorURL).href, operationSignal, cache, onProgress);
          if (!knownBytes) fetchedBytes += data.length;
          for (let offset = 0; offset < data.length; offset += CHUNK_SIZE) {
            const chunk = data.subarray(offset, offset + CHUNK_SIZE);
            let binary = '';
            for (const byte of chunk) binary += String.fromCharCode(byte);
            const ack = await exchange('chunk', { data: btoa(binary) });
            if (ack.op !== 'ok' || ack.detail?.offset !== offset + chunk.length) throw new Error('Guest chunk offset mismatch');
            sentBytes += chunk.length;
            onProgress({ phase: 'serial', path: file.path, received: offset + chunk.length, total: data.length });
          }
          const end = await exchange('end');
          if (end.op !== 'ok') throw new Error('Guest did not verify object');
        }
        await transfer({ ...pin, path: 'transport.json' }, -1, bytes);
        for (let index = 0; index < pkg.files.length; index++) await transfer(pkg.files[index], index);
        checkAbort(operationSignal);
        // The commit is deliberately non-cancellable by a package UI button.
        // VM reset still rejects immediately and destroys that guest generation.
        onProgress({ phase: 'installing', package: name, cancellable: false });
        onCommit();
        checkAbort(operationSignal);
        committed = true;
        const installed = await exchange('install', {}, 300000, false);
        if (installed.op !== 'installed') throw new Error('Guest did not install package');
        const result = await command;
        if (result.status !== 0) throw new Error(`Guest installer failed (status ${result.status})`);
        return { ...installed.detail, fetchedBytes, sentBytes, guestReusedBytes,
          browserElapsedMs: Math.round(performance.now() - started) };
      } catch (error) {
        if (!(error instanceof Error)) error = new Error(String(error));
        rejectPending(error);
        if (command && !committed && !commandSettled && !receiverFailed && !session.signal?.aborted) {
          // Cancel only a live receiver that has not already reported failure;
          // after receiver exit the foreground belongs to the shell again.
          try { await session.send(JSON.stringify({ v: 1, session: sessionID, request: requestID,
            seq: ++seq, op: 'cancel' }) + '\n'); } catch {}
        }
        if (command && !session.signal?.aborted) {
          await Promise.race([command.catch(() => {}), new Promise(resolve => setTimeout(resolve, 65000))]);
          if (!commandSettled) {
            requiresReset = true;
            error.requiresReset = true;
            onProgress({ phase: 'reset-required', message: 'Guest receiver did not exit; reset this VM before terminal input.' });
          }
        }
        throw error;
      } finally {
        unsubscribe();
        busy = requiresReset;
        if (!requiresReset) onProgress({ phase: 'serial-released', package: name });
      }
    },
    dispose() { lifetime.abort(abortError()); },
  };
}

/** Optional DOM fragment; caller supplies a container and owns VM readiness. */
export async function mountCacheTransport(container, transport) {
  const select = document.createElement('select');
  select.setAttribute('aria-label', 'Curated Redox package');
  const install = document.createElement('button'); install.textContent = 'Fetch and install';
  const cancel = document.createElement('button'); cancel.textContent = 'Cancel transfer'; cancel.disabled = true;
  const status = document.createElement('output'); status.setAttribute('aria-live', 'polite');
  container.replaceChildren(select, install, cancel, status);
  let controller;
  try {
    for (const pkg of await transport.catalog()) {
      const option = document.createElement('option'); option.value = pkg.name;
      option.textContent = `${pkg.name} (${pkg.downloadBytes.toLocaleString()} bytes, ${pkg.objectCount} objects)`;
      select.append(option);
    }
    if (!select.options.length) throw new Error('No curated packages in this release');
    if ([...select.options].some(o => o.value === 'fd')) select.value = 'fd';
    status.textContent = 'Catalog loaded; no package payloads downloaded.';
  } catch (error) { install.disabled = true; status.textContent = error.message; }
  cancel.addEventListener('click', () => controller?.abort(abortError()));
  install.addEventListener('click', async () => {
    controller = new AbortController(); install.disabled = true; select.disabled = true; cancel.disabled = false;
    status.textContent = 'Transferring verified cache objects; package installation commits after transfer.';
    try {
      const result = await transport.install(select.value, { signal: controller.signal, onCommit: () => { cancel.disabled = true; } });
      status.textContent = `Installed ${select.value}. Serial: ${result.sentBytes} bytes; guest reuse: ${result.guestReusedBytes} bytes; ${result.browserElapsedMs} ms. Run /nix/var/snix/profiles/default/bin/${select.value} --version in the terminal.`;
    } catch (error) {
      status.textContent = `Not completed: ${error.message}${error.requiresReset ? ' Reset this VM before continuing.' : ''}`;
      if (error.requiresReset) container.dataset.resetRequired = 'true';
    }
    finally { controller = null; install.disabled = container.dataset.resetRequired === 'true';
      select.disabled = install.disabled; cancel.disabled = true; }
  });
  return () => { controller?.abort(abortError()); transport.dispose(); container.replaceChildren(); };
}
