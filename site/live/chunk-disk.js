/* SPDX-License-Identifier: MIT
 * Verified immutable base, volatile per-session sector overlay. No persistence.
 * Clean cache + concurrency*chunkSize bounds fetched data; callers additionally
 * bound their read buffers. Dirty quota is allocated sector bytes, never evicted.
 * transferredBytes counts decoded object-body bytes (including failed objects);
 * use Resource Timing transferSize for actual cold/warm wire measurements.
 * Error errno values are stable Linux-facing codes; the C bridge maps them to
 * the pinned Emscripten libc values, which are not numerically identical.
 */
const SHA256 = /^[a-f0-9]{64}$/;
const fail = (message, errno = 5) => Object.assign(new Error(message), { errno });
const integer = (n, min, max) => Number.isSafeInteger(n) && n >= min && n <= max;
async function digest(bytes) {
  const hash = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(hash), b => b.toString(16).padStart(2, '0')).join('');
}
async function fetchBytes(url, length, hash, signal, counters) {
  const response = await fetch(url, { signal, cache: 'no-cache', redirect: 'error' });
  if (response.status !== 200) throw fail('Disk object HTTP ' + response.status);
  // Content-Length can describe compressed transfer bytes; enforce decoded size
  // while streaming rather than trusting either the header or arrayBuffer().
  if (!response.body) throw fail('Disk object has no response body');
  const result = new Uint8Array(length);
  const reader = response.body.getReader();
  let offset = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      if (counters) counters.transferredBytes += value.byteLength;
      if (offset + value.byteLength > length) throw fail('Oversized disk object');
      result.set(value, offset);
      offset += value.byteLength;
    }
  } catch (error) {
    await reader.cancel().catch(() => {});
    throw error;
  } finally {
    reader.releaseLock();
  }
  if (offset !== length || await digest(result) !== hash) throw fail('Disk object length/hash mismatch');
  return result;
}

export class ChunkDisk {
  constructor(manifest, manifestURL, { cleanCacheBytes = 16 * 1048576,
    dirtyLimitBytes = 64 * 1048576, concurrency = 4, maxPending = 128,
    maxRequestBytes = 1048576, signal } = {}) {
    if (manifest.schemaVersion !== 1 || manifest.format !== 'redox-chunk-disk-v1' ||
        manifest.sectorSize !== 512 || !integer(manifest.logicalSize, 512, Number.MAX_SAFE_INTEGER) ||
        manifest.logicalSize % 512 || !integer(manifest.chunkSize, 512, 16777216) ||
        manifest.chunkSize % 512 || !SHA256.test(manifest.imageSha256) ||
        !Array.isArray(manifest.chunks) ||
        manifest.chunks.length !== Math.ceil(manifest.logicalSize / manifest.chunkSize)) {
      throw fail('Invalid disk manifest', 22);
    }
    this.manifest = structuredClone(manifest);
    this.url = new URL(manifestURL);
    for (let i = 0; i < this.manifest.chunks.length; i++) {
      const c = this.manifest.chunks[i];
      const length = Math.min(manifest.chunkSize, manifest.logicalSize - i * manifest.chunkSize);
      if (c.length !== length || !SHA256.test(c.sha256) || typeof c.zero !== 'boolean' ||
          (c.zero ? c.url !== undefined : c.url !== 'chunks/' + c.sha256)) {
        throw fail('Invalid disk chunk ' + i, 22);
      }
      Object.freeze(c);
    }
    Object.freeze(this.manifest.chunks);
    Object.freeze(this.manifest);
    if (!integer(cleanCacheBytes, 0, Number.MAX_SAFE_INTEGER) ||
        !integer(dirtyLimitBytes, 0, Number.MAX_SAFE_INTEGER) ||
        !integer(concurrency, 1, 32) || !integer(maxPending, concurrency, 4096) ||
        !integer(maxRequestBytes, 512, 16777216)) throw fail('Invalid disk limits', 22);
    Object.assign(this, { cleanCacheBytes, dirtyLimitBytes, concurrency, maxPending, maxRequestBytes });
    this.reset();
    if (signal) {
      signal.addEventListener('abort', () => this.close(), { once: true });
      if (signal.aborted) this.close();
    }
  }
  get logicalSize() { return this.manifest.logicalSize; }
  get imageSha256() { return this.manifest.imageSha256; }
  get stats() { return { ...this.state.stats, inflight: this.state.active,
    pending: this.state.pending.size, dirtyOverlayBytes: this.state.overlay.size * 512 }; }
  reset() {
    if (this.state) this.state.controller.abort();
    this.state = { controller: new AbortController(), cache: new Map(), pending: new Map(),
      overlay: new Map(), active: 0, waiters: [], queuedWrites: 0, writes: Promise.resolve(),
      stats: { transferredBytes: 0, cacheHits: 0, cacheMisses: 0, coalesced: 0, cleanCacheBytes: 0 } };
  }
  close() { this.state.controller.abort(); this.state.cache.clear(); this.state.overlay.clear();
    this.state.stats.cleanCacheBytes = 0; }
  check(state) { if (state.controller.signal.aborted) throw fail('Disk session cancelled', 125); }
  range(offset, length) {
    if (!integer(offset, 0, this.logicalSize) || !integer(length, 0, this.maxRequestBytes) ||
        offset + length > this.logicalSize) throw fail('Invalid disk request range', 22);
  }
  async slot(state) {
    this.check(state);
    if (state.active >= this.concurrency) {
      await new Promise((resolve, reject) => {
        const abort = () => { state.waiters.splice(state.waiters.indexOf(wake), 1);
          reject(fail('Disk session cancelled', 125)); };
        const wake = () => { state.controller.signal.removeEventListener('abort', abort); resolve(); };
        state.waiters.push(wake);
        state.controller.signal.addEventListener('abort', abort, { once: true });
      });
      this.check(state);
      // The departing owner transfers its slot to this waiter.
    } else state.active++;
  }
  release(state) { const next = state.waiters.shift(); if (next) next(); else state.active--; }
  async chunk(index, state) {
    this.check(state);
    if (state.cache.has(index)) {
      const bytes = state.cache.get(index);
      state.cache.delete(index); state.cache.set(index, bytes);
      state.stats.cacheHits++;
      return bytes;
    }
    if (state.pending.has(index)) { state.stats.coalesced++; return state.pending.get(index); }
    if (state.pending.size >= this.maxPending) throw fail('Disk request queue full', 16);
    state.stats.cacheMisses++;
    const task = (async () => {
      await this.slot(state);
      try {
        const entry = this.manifest.chunks[index];
        let bytes;
        if (entry.zero) {
          bytes = new Uint8Array(entry.length);
          if (await digest(bytes) !== entry.sha256) throw fail('Zero chunk hash mismatch');
        } else bytes = await fetchBytes(new URL(entry.url, this.url), entry.length,
          entry.sha256, state.controller.signal, state.stats);
        this.check(state);
        if (bytes.byteLength <= this.cleanCacheBytes) {
          while (state.stats.cleanCacheBytes + bytes.byteLength > this.cleanCacheBytes) {
            const key = state.cache.keys().next().value;
            state.stats.cleanCacheBytes -= state.cache.get(key).byteLength;
            state.cache.delete(key);
          }
          state.cache.set(index, bytes); state.stats.cleanCacheBytes += bytes.byteLength;
        }
        return bytes;
      } catch (error) { this.check(state); throw error; }
      finally { this.release(state); }
    })();
    state.pending.set(index, task);
    try { return await task; } finally { state.pending.delete(index); }
  }
  async readAt(offset, length, state) {
    this.check(state);
    // Snapshot references before any await. Sector arrays are immutable after
    // publication, so a racing write cannot tear a read across await points.
    const sectors = new Map();
    for (let n = Math.floor(offset / 512); n < Math.ceil((offset + length) / 512); n++) {
      if (state.overlay.has(n)) sectors.set(n, state.overlay.get(n));
    }
    const result = new Uint8Array(length);
    let pos = offset;
    let baseIndex = -1, baseBytes;
    while (pos < offset + length) {
      const sector = Math.floor(pos / 512);
      const within = pos % 512;
      const take = Math.min(512 - within, offset + length - pos);
      let bytes = sectors.get(sector);
      let start = within;
      if (!bytes) {
        const index = Math.floor(pos / this.manifest.chunkSize);
        if (index !== baseIndex) { baseBytes = await this.chunk(index, state); baseIndex = index; }
        bytes = baseBytes;
        start = pos % this.manifest.chunkSize;
      }
      result.set(bytes.subarray(start, start + take), pos - offset);
      pos += take;
    }
    this.check(state);
    return result;
  }
  async read(offset, length) {
    this.range(offset, length);
    const state = this.state;
    await state.writes;
    return this.readAt(offset, length, state);
  }
  write(offset, source) {
    if (!(source instanceof Uint8Array)) return Promise.reject(fail('Write requires bytes', 22));
    this.range(offset, source.byteLength);
    const state = this.state;
    if (state.queuedWrites >= this.maxPending) return Promise.reject(fail('Disk write queue full', 16));
    const data = source.slice();
    state.queuedWrites++;
    const task = state.writes.then(async () => {
      this.check(state);
      if (!data.length) return;
      const first = Math.floor(offset / 512), end = Math.ceil((offset + data.length) / 512);
      let added = 0;
      for (let n = first; n < end; n++) if (!state.overlay.has(n)) added++;
      if ((state.overlay.size + added) * 512 > this.dirtyLimitBytes) throw fail('Disk overlay quota exhausted', 28);
      const prepared = [];
      for (let n = first; n < end; n++) {
        const begin = Math.max(offset, n * 512), finish = Math.min(offset + data.length, (n + 1) * 512);
        const sector = begin === n * 512 && finish === (n + 1) * 512 ? new Uint8Array(512) :
          await this.readAt(n * 512, 512, state);
        sector.set(data.subarray(begin - offset, finish - offset), begin - n * 512);
        prepared.push([n, sector]);
      }
      this.check(state);
      for (const [n, sector] of prepared) state.overlay.set(n, sector);
    });
    // An I/O failure must not poison every subsequent write or flush.
    const finished = task.finally(() => { state.queuedWrites--; });
    state.writes = finished.catch(() => {});
    return finished;
  }
  async flush() {
    const state = this.state;
    await state.writes;
    this.check(state);
    // All writes are committed to this session's RAM, not durable storage.
  }
  async discard(offset, length) {
    this.range(offset, length);
    this.check(this.state);
    // Deliberately unsupported: never revert trimmed guest data to base bytes.
    throw fail('Discard is not supported', 95);
  }
}

export async function loadChunkDisk(asset, options = {}) {
  if (!asset || !SHA256.test(asset.sha256) || !integer(asset.size, 1, 64 * 1048576)) {
    throw fail('Disk manifest must have pinned SHA-256 and size', 22);
  }
  const url = new URL(asset.url, globalThis.location?.href);
  const bytes = await fetchBytes(url, asset.size, asset.sha256, options.signal);
  return new ChunkDisk(JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)), url, options);
}

// Browser comparison protocol (no improvement is asserted by this module):
// use the SAME patched engine/machine/guest RAM for raw preload and lazy modes.
// In fresh browser contexts record time to the ready marker and completion of
// the same guest file write/read + Snix fixtures. Repeat once with warm HTTP /
// compiled-Wasm caches, but a fresh guest overlay. Sum ResourceTiming.transferSize
// for same-origin resources; record disk.stats separately. Sample browser-process
// peak RSS throughout boot/workflow, not only final heap size; fixed 2048MiB guest
// RAM is unchanged. Report cold/warm wire bytes, peak memory, timings and cache /
// dirty peaks together. Compressed sparse raw files can transfer much less than
// their logical size, so use observed numbers, never logical-size estimates.
//
// Called on the engine's main-thread Module before its preRun/main. The C driver
// checks image identity on every operation. It never falls back to preload.
export function attachChunkDisk(module, disk, nodeName = 'redox') {
  if (!(disk instanceof ChunkDisk) || !/^[A-Za-z0-9_-]+$/.test(nodeName)) throw fail('Invalid disk attachment', 22);
  module.redoxChunkDisk = disk;
  return ['-blockdev', 'driver=browser-chunk,node-name=' + nodeName + ',size=' + disk.logicalSize +
    ',image-id=' + disk.imageSha256, '-device', 'virtio-blk-pci,drive=' + nodeName];
}
