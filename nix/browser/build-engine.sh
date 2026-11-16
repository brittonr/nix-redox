#!/usr/bin/env bash
# Pinned QEMU + TryNix numbered patches via Docker/Emscripten, not Nix-native.
set -euo pipefail
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: build-browser-engine OUTPUT [baseline|extended]" >&2
  exit 2
fi
: "${REDOX_ENGINE_SOURCE:?run the build-browser-engine Nix app}"
: "${TRYNIX_SOURCE:?run the build-browser-engine Nix app}"
: "${REDOX_ENGINE_PATCHES:?run the build-browser-engine Nix app}"
: "${REDOX_EMSDK_IMAGE:?missing immutable Emscripten image pin}"
: "${REDOX_SOURCE_BUNDLE:?missing corresponding sources and notices}"
out=$(realpath -m "$1")
mode=${2:-baseline}
case "$mode" in baseline|extended) ;; *) echo 'mode must be baseline or extended' >&2; exit 2 ;; esac
if [ -e "$out" ]; then
  echo "output already exists: $out" >&2
  exit 2
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
rsync -a "$REDOX_ENGINE_SOURCE/" "$work/qemu/"
chmod -R u+w "$work/qemu"
cp "$TRYNIX_SOURCE/tools/build-engine.sh" "$work/build-engine.sh"
chmod u+w "$work/build-engine.sh"
python3 - "$work/qemu/Dockerfile" "$REDOX_EMSDK_IMAGE" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
needle = 'FROM emscripten/emsdk:$EMSDK_VERSION_QEMU AS build-base'
assert s.count(needle) == 1
p.write_text(s.replace(needle, 'FROM ' + sys.argv[2] + ' AS build-base'))
PY
if [ "$mode" = extended ]; then
  # These backends are absent from the imported upstream release.
  display_patch="$REDOX_ENGINE_PATCHES/display/0001-browser-display.patch"
  chunk_patch="$REDOX_ENGINE_PATCHES/browser-chunk.patch"
  chunk_source="$REDOX_ENGINE_PATCHES/browser-chunk.c"
  for required in "$display_patch" "$chunk_patch" "$chunk_source"; do
    if [ ! -f "$required" ]; then echo "missing extended engine source: $required" >&2; exit 1; fi
  done
  patch -d "$work/qemu" -p1 < "$display_patch"
  cp "$chunk_source" "$work/qemu/block/browser-chunk.c"
  patch -d "$work/qemu" -p1 < "$chunk_patch"
  python3 - "$work/build-engine.sh" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
needle = '--without-default-features --enable-system'
assert s.count(needle) == 1
memory = '-sTOTAL_MEMORY=2300MB'
assert s.count(memory) == 1
# The 1 GiB guest plus 1 GiB preload disk exhausted the fixed 2300 MiB
# heap at a measured sbrk request of 2469924272 bytes (mimalloc arena).
# Keep fixed shared memory: growing it would invalidate retained heap views.
# 3072 MiB provides workload headroom without changing the baseline ABI.
s = s.replace(memory, '-sTOTAL_MEMORY=3072MB')
p.write_text(s.replace(needle, needle + ' --enable-pixman --disable-sdl'))
PY
fi
# Feed hashed sources into the upstream library build steps; only apt build
# tools remain online and non-hermetic.
mkdir -p "$work/toolchain"
for archive in glib-2.75.0.tar.xz pixman-0.42.2.tar.gz zlib-1.3.1.tar.xz libffi.tar.gz xterm-pty-0.10.1.tgz; do
  cp "$REDOX_SOURCE_BUNDLE/source/$archive" "$work/toolchain/$archive"
done
python3 - "$work/qemu/Dockerfile" "$work/toolchain/Dockerfile" <<'PY'
import pathlib, sys
s = pathlib.Path(sys.argv[1]).read_text()
replacements = {
    'RUN curl -Ls https://zlib.net/zlib-$ZLIB_VERSION.tar.xz | tar xJC /zlib --strip-components=1': 'COPY zlib-1.3.1.tar.xz /zlib.tar.xz\nRUN tar xJf /zlib.tar.xz -C /zlib --strip-components=1',
    'RUN curl -Lks https://download.gnome.org/sources/glib/${GLIB_MINOR_VERSION}/glib-$GLIB_VERSION.tar.xz | tar xJC /glib --strip-components=1': 'COPY glib-2.75.0.tar.xz /glib.tar.xz\nRUN tar xJf /glib.tar.xz -C /glib --strip-components=1',
    'RUN git clone https://github.com/libffi/libffi /libffi': 'COPY libffi.tar.gz /libffi.tar.gz\nRUN tar xzf /libffi.tar.gz -C /libffi --strip-components=1',
    'RUN git checkout $FFI_VERSION': '# libffi commit is pinned by the supplied source archive',
    'RUN git clone  https://gitlab.freedesktop.org/pixman/pixman /pixman/': 'COPY pixman-0.42.2.tar.gz /pixman.tar.gz\nRUN tar xzf /pixman.tar.gz -C /pixman --strip-components=1',
    'RUN git checkout pixman-$PIXMAN_VERSION': '# pixman version is pinned by the supplied source archive',
    'RUN NOCONFIGURE=y ./autogen.sh': '# Release tarball already includes generated configure; no git bootstrap',
    'RUN npm i xterm-pty@v0.10.1': 'COPY xterm-pty-0.10.1.tgz /xterm-pty.tgz\nRUN mkdir -p /build/node_modules/xterm-pty && tar xzf /xterm-pty.tgz -C /build/node_modules/xterm-pty --strip-components=1',
}
for old, new in replacements.items():
    if s.count(old) != 1:
        raise SystemExit('pinned Docker recipe changed: ' + old)
    s = s.replace(old, new)
pathlib.Path(sys.argv[2]).write_text(s)
PY
# Refuse reuse of an unrelated toolchain image under upstream's fixed tag.
toolchain_hash=$(cd "$work/toolchain" && sha256sum Dockerfile *.tar.* *.tgz | sha256sum | cut -d' ' -f1)
if docker image inspect trynix-buildqemu >/dev/null 2>&1; then
  existing=$(docker image inspect --format '{{index .Config.Labels "org.redox.toolchain-dockerfile"}}' trynix-buildqemu)
  if [ "$existing" != "$toolchain_hash" ]; then
    echo 'trynix-buildqemu exists without matching source label; retag it explicitly before building' >&2
    exit 1
  fi
else
  docker build --label "org.redox.toolchain-dockerfile=$toolchain_hash" -t trynix-buildqemu "$work/toolchain"
fi
TRYNIX_PATCHES="$TRYNIX_SOURCE/patches" bash "$work/build-engine.sh" "$work/qemu" "$out"
cp -r "$REDOX_SOURCE_BUNDLE/." "$out/"
chmod u+w "$out/source"
cp "$TRYNIX_SOURCE/tools/build-engine.sh" "$out/source/upstream-build-engine.sh"
cp "$work/build-engine.sh" "$out/source/effective-build-engine.sh"
cp "$REDOX_ENGINE_SOURCE/Dockerfile" "$out/source/upstream-Dockerfile"
cp "$work/toolchain/Dockerfile" "$out/source/Dockerfile"
cp -r "$TRYNIX_SOURCE/patches" "$out/source/trynix-patches"
if [ "$mode" = extended ]; then cp -r "$REDOX_ENGINE_PATCHES" "$out/source/redox-patches"; fi
# Actual image ID and output hashes are recorded; no byte reproducibility claim.
# SDK image and linked library sources are pinned; apt tools are online.
docker image inspect trynix-buildqemu > "$out/source/toolchain-image.json"
python3 - "$out" "$mode" "$REDOX_ENGINE_SOURCE" "$TRYNIX_SOURCE" <<'PY'
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
files = {name: {'sha256': hashlib.sha256((out / name).read_bytes()).hexdigest(), 'size': (out / name).stat().st_size} for name in ('out.js', 'qemu-system-x86_64.wasm', 'qemu-system-x86_64.worker.js')}
patches = {str(p.relative_to(out / 'source')): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((out / 'source').rglob('*')) if p.is_file() and p.suffix in ('.patch', '.c')}
pins = json.loads((out / 'source/engine-pins.json').read_text())
identity = {'schemaVersion': 1, 'kind': 'docker-emscripten-source-build', 'mode': sys.argv[2], 'qemuRevision': pins['qemuRevision'], 'trynixRevision': pins['trynixRevision'], 'qemuSource': sys.argv[3], 'trynixSource': sys.argv[4], 'emscripten': '3.1.50', 'xtermPty': '0.10.1', 'hermetic': False, 'files': files, 'patches': patches, 'capabilities': {'browserChunkDiskV1': sys.argv[2] == 'extended', 'browserDisplayV1': sys.argv[2] == 'extended'}}
identity['memory'] = {'initialBytes': (3072 if sys.argv[2] == 'extended' else 2300) * 1024 * 1024, 'maximumBytes': (3072 if sys.argv[2] == 'extended' else 2300) * 1024 * 1024, 'growth': False, 'allocator': 'mimalloc'}
identity['effectiveBuildRecipe'] = {'path': 'source/effective-build-engine.sh', 'sha256': hashlib.sha256((out / 'source/effective-build-engine.sh').read_bytes()).hexdigest()}
for path in (out / 'source/build-provenance.json', out / 'engine-identity.json'):
    path.write_text(json.dumps(identity, indent=2) + '\n')
PY
python3 "$out/source/finalize-engine.py" "$out" --pins "$out/source/engine-pins.json"
