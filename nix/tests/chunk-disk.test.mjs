// Run: node --test nix/tests/chunk-disk.test.mjs
// Real exporter + real HTTP transport, never a mocked Fetch or disk model.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash, webcrypto } from 'node:crypto';
if (!globalThis.crypto) globalThis.crypto = webcrypto;
const code = await readFile(new URL('../../site/live/chunk-disk.js', import.meta.url));
const { loadChunkDisk } = await import('data:text/javascript;base64,' + code.toString('base64'));
const sha = bytes => createHash('sha256').update(bytes).digest('hex');

async function fixture(t, options = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'redox-chunks-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const image = Buffer.alloc(8 * 4096 + 1536);
  let seed = 42;
  for (let i = 0; i < image.length; i++) { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; image[i] = seed >>> 24; }
  image.fill(0, 4096, 8192);
  image.write('EFI PART', 512);
  await writeFile(join(directory, 'reference.raw'), image);
  const output = join(directory, 'objects');
  const command = spawnSync('python3', [new URL('../browser/chunk-disk.py', import.meta.url).pathname,
    join(directory, 'reference.raw'), output, '--chunk-size', '4096'], { encoding: 'utf8' });
  assert.equal(command.status, 0, command.stderr);
  const manifestBytes = await readFile(join(output, 'manifest.json'));
  const manifest = JSON.parse(manifestBytes);
  const control = { fault: null, requests: new Map(), active: 0, peak: 0, hold: false, releases: [] };
  const server = createServer(async (request, response) => {
    control.requests.set(request.url, (control.requests.get(request.url) || 0) + 1);
    control.active++; control.peak = Math.max(control.peak, control.active);
    response.on('close', () => { control.active--; });
    if (control.hold && request.url.includes('/chunks/')) await new Promise(resolve => control.releases.push(resolve));
    try {
      const path = request.url.slice(1);
      let bytes = await readFile(join(output, path));
      if (path.startsWith('chunks/')) {
        if (control.fault === 'missing') { response.writeHead(404).end(); return; }
        if (control.fault === 'corrupt') { bytes = Buffer.from(bytes); bytes[0] ^= 255; }
        if (control.fault === 'stale') bytes = Buffer.from(image.subarray(8192, 8192 + bytes.length));
        if (control.fault === 'truncated') bytes = bytes.subarray(0, bytes.length - 1);
        if (control.fault === 'oversized') bytes = Buffer.concat([bytes, Buffer.from([0])]);
      }
      response.writeHead(200, { 'Content-Length': bytes.length }); response.end(bytes);
    } catch { response.writeHead(404).end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { for (const release of control.releases.splice(0)) release(); server.closeAllConnections(); server.close(); });
  const asset = { url: 'http://127.0.0.1:' + server.address().port + '/manifest.json',
    size: manifestBytes.length, sha256: sha(manifestBytes) };
  const open = extra => loadChunkDisk(asset, { cleanCacheBytes: 4096, dirtyLimitBytes: 8192, concurrency: 2, ...options, ...extra });
  return { image, manifest, manifestBytes, asset, open, control, output, directory };
}

test('deterministic exporter and sequential/random/boundary/final-partial reads match raw reference', async t => {
  const f = await fixture(t); const disk = await f.open();
  assert.equal(disk.imageSha256, sha(f.image));
  assert.equal(f.manifest.chunks[1].zero, true);
  const again = spawnSync('python3', [new URL('../browser/chunk-disk.py', import.meta.url).pathname,
    join(f.directory, 'reference.raw'), join(f.directory, 'second'), '--chunk-size', '4096']);
  assert.equal(again.status, 0);
  assert.deepEqual(await readFile(join(f.directory, 'second', 'manifest.json')), f.manifestBytes);
  const compare = async (offset, length) => assert.deepEqual(Buffer.from(await disk.read(offset, length)), f.image.subarray(offset, offset + length));
  for (let offset = 0; offset < f.image.length; offset += 777) await compare(offset, Math.min(777, f.image.length - offset));
  for (const offset of [0, 511, 512, 4095, 4096, 8191, f.image.length - 1]) await compare(offset, Math.min(1537, f.image.length - offset));
  let random = 1;
  for (let n = 0; n < 150; n++) {
    random = (Math.imul(random, 1103515245) + 12345) >>> 0;
    const offset = random % f.image.length;
    await compare(offset, Math.min(1 + random % 6000, f.image.length - offset));
    assert.ok(disk.stats.cleanCacheBytes <= 4096);
  }
  const concurrentOffsets = [0, 8191, 12287, 16380, 20480, 24570, 28671, f.image.length - 513];
  const concurrent = await Promise.all(concurrentOffsets.map(offset => disk.read(offset, 513)));
  concurrent.forEach((bytes, i) => assert.deepEqual(Buffer.from(bytes), f.image.subarray(concurrentOffsets[i], concurrentOffsets[i] + 513)));
  assert.equal(f.control.requests.get('/chunks/' + f.manifest.chunks[1].sha256), undefined);
});

test('partial writes, eviction, concurrent writers, session isolation, reset and flush', async t => {
  const f = await fixture(t); const disk = await f.open({ dirtyLimitBytes: 65536 });
  const other = await f.open(); const reference = Buffer.from(f.image);
  const writes = [[4090, Buffer.alloc(19, 7)], [0, Buffer.from('GPT')], [4094, Buffer.alloc(513, 8)],
    [f.image.length - 3, Buffer.from([3, 2, 1])]];
  await Promise.all(writes.map(([offset, data]) => { reference.set(data, offset); return disk.write(offset, data); }));
  let random = 7;
  for (let n = 0; n < 80; n++) {
    random = (Math.imul(random, 1664525) + 1013904223) >>> 0;
    const offset = random % reference.length;
    const data = Buffer.alloc(Math.min(1 + random % 900, reference.length - offset), random & 255);
    await disk.write(offset, data); reference.set(data, offset);
    assert.deepEqual(Buffer.from(await disk.read(offset, data.length)), data);
  }
  await disk.flush();
  for (let offset = 0; offset < reference.length; offset += 997) {
    const length = Math.min(997, reference.length - offset);
    assert.deepEqual(Buffer.from(await disk.read(offset, length)), reference.subarray(offset, offset + length));
  }
  assert.deepEqual(Buffer.from(await other.read(4090, 1024)), f.image.subarray(4090, 5114));
  assert.ok(disk.stats.cleanCacheBytes <= 4096);
  await other.write(0, new Uint8Array([77, 78, 79]));
  assert.deepEqual(Buffer.from(await disk.read(0, 3)), reference.subarray(0, 3));
  assert.deepEqual(Array.from(await other.read(0, 3)), [77, 78, 79]);
  await assert.rejects(disk.discard(0, 512), { errno: 95 });
  disk.reset();
  assert.equal(disk.stats.dirtyOverlayBytes, 0);
  assert.deepEqual(Buffer.from(await disk.read(4090, 1024)), f.image.subarray(4090, 5114));
});

test('quota failure does not partially modify a multi-sector write or poison later operations', async t => {
  const f = await fixture(t); const disk = await f.open({ dirtyLimitBytes: 512 });
  await disk.write(0, new Uint8Array([9]));
  await assert.rejects(disk.write(511, new Uint8Array([8, 7])), { errno: 28 });
  const expected = Buffer.from(f.image.subarray(0, 1024)); expected[0] = 9;
  assert.deepEqual(Buffer.from(await disk.read(0, 1024)), expected);
  await disk.write(1, new Uint8Array([6])); await disk.flush();
  assert.equal(disk.stats.dirtyOverlayBytes, 512);
  await disk.write(1, new Uint8Array(0));
  assert.equal(disk.stats.dirtyOverlayBytes, 512);
});

test('coalescing, bounded concurrent real Fetch, reset cancels held reads and queued requests', async t => {
  const f = await fixture(t); const disk = await f.open(); f.control.hold = true;
  const operations = [disk.read(0, 512), disk.read(0, 512), disk.read(8192, 512), disk.read(12288, 512)];
  // Attach rejection consumers before reset to avoid test-runner unhandled errors.
  const settled = Promise.allSettled(operations);
  while (f.control.releases.length < 2) await new Promise(resolve => setTimeout(resolve, 1));
  assert.ok(f.control.peak <= 2);
  assert.ok(disk.stats.coalesced >= 1);
  disk.reset();
  for (const release of f.control.releases.splice(0)) release(); f.control.hold = false;
  const results = await settled;
  assert.ok(results.every(result => result.status === 'rejected'));
  assert.deepEqual(Buffer.from(await disk.read(0, 512)), f.image.subarray(0, 512));
  assert.equal(f.control.requests.get('/chunks/' + f.manifest.chunks[0].sha256), 2);
});

for (const fault of ['missing', 'corrupt', 'stale', 'truncated', 'oversized']) {
  test(fault + ' object rejects reads instead of returning zeros', async t => {
    const f = await fixture(t); const disk = await f.open(); f.control.fault = fault;
    await assert.rejects(disk.read(0, 512));
    await assert.rejects(disk.read(f.image.length - 512, 512));
    assert.equal(disk.stats.cleanCacheBytes, 0);
    f.control.fault = null;
    assert.deepEqual(Buffer.from(await disk.read(0, 512)), f.image.subarray(0, 512));
  });
}

test('manifest digest pinning rejects altered metadata', async t => {
  const f = await fixture(t);
  await assert.rejects(loadChunkDisk({ ...f.asset, sha256: '0'.repeat(64) }));
});

test('pending queue is bounded and zero manifest corruption is an I/O error', async t => {
  const f = await fixture(t); const disk = await f.open({ concurrency: 1, maxPending: 1 });
  f.control.hold = true;
  const first = disk.read(0, 512);
  const rejectedFirst = first.catch(error => error);
  while (!f.control.releases.length) await new Promise(resolve => setTimeout(resolve, 1));
  await assert.rejects(disk.read(8192, 512), { errno: 16 });
  disk.close();
  for (const release of f.control.releases.splice(0)) release();
  assert.equal((await rejectedFirst).errno, 125);
  f.control.hold = false;
  const changed = structuredClone(f.manifest); changed.chunks[1].sha256 = '0'.repeat(64);
  const badBytes = Buffer.from(JSON.stringify(changed));
  await writeFile(join(f.output, 'manifest.json'), badBytes);
  const invalidZero = await loadChunkDisk({ ...f.asset, sha256: sha(badBytes), size: badBytes.length });
  await assert.rejects(invalidZero.read(4096, 512), { errno: 5 });
});
