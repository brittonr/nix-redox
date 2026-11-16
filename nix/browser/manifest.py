#!/usr/bin/env python3
"""Assemble a relocatable, content-addressed browser release (no network access)."""
import argparse
import base64
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

def safe_artifact_path(value):
    return isinstance(value, str) and all(
        segment not in ("", ".", "..") and all(character.isascii() and (character.isalnum() or character in "_,.-") for character in segment)
        for segment in value.split("/")
    )


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def asset(root, source, name=None, **extra):
    source = Path(source)
    if not source.is_file():
        raise ValueError(f"required asset unavailable: {source}")
    sha = digest(source)
    target = root / "assets" / sha / (name or source.name)
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        shutil.copyfile(source, target)
    return {"url": "../../" + target.relative_to(root).as_posix(), "sha256": sha,
            "size": source.stat().st_size, **extra}


def unique(root, pattern):
    candidates = sorted(Path(root).glob(pattern))
    if len(candidates) != 1:
        raise ValueError(f"expected one {pattern} in {root}, found {candidates}")
    return candidates[0]


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical(value) + b"\n")


RUNTIME_KEYS = ("schemaVersion", "sourceRevision", "target", "machine", "machineHash", "assets",
                "fixtures", "engineIdentity", "engineFeatures", "firmwareFiles", "cacheTransport", "cacheIdentity", "guestIdentity")


def runtime_identity(manifest):
    return hashlib.sha256(canonical({key: manifest[key] for key in RUNTIME_KEYS if key in manifest})).hexdigest()


def release_identity(manifest):
    return hashlib.sha256(canonical({key: value for key, value in manifest.items() if key != "revision"})).hexdigest()


def assemble(args):
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}", args.revision):
        raise ValueError("source revision must be a nonempty URL-safe identity")
    root = Path(args.out)
    if root.exists() and any(root.iterdir()):
        raise ValueError("assembly output must be empty; publish complete new trees rather than mutating saved revision hardlinks")
    root.mkdir(parents=True, exist_ok=True)
    shutil.copytree(args.site, root, dirs_exist_ok=True)
    # copytree preserves Nix-store 0555/0444 modes. Make only the fresh staging
    # copies writable before adding assets or overlaying the evaluator package.
    for path in [root, *root.rglob("*")]:
        path.chmod(path.stat().st_mode | (0o700 if path.is_dir() else 0o600))
    machine = json.loads(Path(args.machine).read_bytes())
    ram = machine.get("ramMiB") if isinstance(machine, dict) else None
    if type(ram) is not int or not 1 <= ram <= 2047 or machine.get("ram") != f"{ram}M":
        raise ValueError("pinned QEMU-WASM requires 1..2047 MiB and a matching ram value in MiB")
    fixtures = json.loads((Path(args.image) / "fixtures/catalog.json").read_bytes())
    engine = Path(args.engine)
    js = sorted(p for p in engine.glob("*.js") if "worker" not in p.name)
    if len(js) != 1:
        raise ValueError(f"expected one engine factory JS, found {js}")
    assets = {
        "engine": asset(root, js[0]),
        "wasm": asset(root, unique(engine, "*.wasm")),
        "worker": asset(root, unique(engine, "*worker*.js")),
        "firmware": asset(root, args.firmware),
        "efi": asset(root, Path(args.image) / "boot/BOOTX64.EFI"),
    }
    # Hash transfer bytes, not the uncompressed image. Do not serve Content-Encoding:
    # the guest loader verifies the gzip payload before explicitly decompressing it.
    disk = Path(args.image) / "redox.img"
    gz = root / "disk.img.gz"
    with disk.open("rb") as src, gz.open("wb") as dst:
        with gzip.GzipFile(filename="", mode="wb", fileobj=dst, mtime=0) as zipped:
            shutil.copyfileobj(src, zipped, 1024 * 1024)
    assets["disk"] = asset(root, gz, encoding="gzip", logicalSize=disk.stat().st_size,
                           rawSha256=digest(disk))
    gz.unlink()
    for role, name in (("xterm", "xterm.js"), ("xtermCss", "xterm.css"), ("pty", "xterm-pty.js")):
        source = Path(args.vendor) / name
        # Preserve module-relative vendor imports in addition to immutable identities.
        target = root / "vendor" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        assets[role] = asset(root, source)
    manifest = {
        "schemaVersion": 1, "sourceRevision": args.revision,
        "target": "x86_64-unknown-redox", "machine": machine,
        "machineHash": hashlib.sha256(canonical(machine)).hexdigest(),
        "assets": assets, "fixtures": fixtures,
        "capabilities": {"secureContext": True, "crossOriginIsolated": True,
                         "sharedArrayBuffer": True, "webAssembly": True,
                         "workers": True},
    }
    identity = engine / "engine-identity.json"
    if not identity.is_file():
        identity = engine / "engine-pins.json"
    if identity.is_file():
        provenance = json.loads(identity.read_bytes())
        for role, filename in (("engine", js[0].name), ("wasm", unique(engine, "*.wasm").name),
                               ("worker", unique(engine, "*worker*.js").name)):
            declared = provenance.get("files", {}).get(filename)
            if isinstance(declared, str) and declared.startswith("sha256-"):
                expected = {"sha256": base64.b64decode(declared[7:], validate=True).hex()}
            elif isinstance(declared, dict):
                expected = declared
            else:
                raise ValueError(f"engine provenance has no immutable identity for {filename}")
            if expected.get("sha256") != assets[role]["sha256"] or (
                    "size" in expected and expected["size"] != assets[role]["size"]):
                raise ValueError(f"engine provenance/payload mismatch: {filename}")
        manifest["engineIdentity"] = asset(root, identity)
        supported = provenance.get("capabilities", {})
        manifest["engineFeatures"] = [name for key, name in (
            ("browserChunkDiskV1", "browser-chunk"), ("browserDisplayV1", "browser-display")) if supported.get(key) is True]
    else:
        manifest["engineFeatures"] = []
    if args.disk_chunker and "browser-chunk" in manifest["engineFeatures"]:
        with tempfile.TemporaryDirectory() as temporary:
            chunks = Path(temporary) / "disk"
            subprocess.run(["python3", args.disk_chunker, str(disk), str(chunks), "--chunk-size", "1048576"], check=True)
            descriptor = asset(root, chunks / "manifest.json", name="disk-chunks.json")
            destination = root / descriptor["url"].removeprefix("../../")
            shutil.copytree(chunks / "chunks", destination.parent / "chunks", dirs_exist_ok=True)
            assets["diskChunks"] = descriptor
    manifest["guestIdentity"] = {"sha256": assets["disk"]["rawSha256"], "logicalSize": assets["disk"]["logicalSize"]}
    if args.firmware_notices:
        firmware_root = Path(args.firmware_notices)
        manifest["firmwareFiles"] = {}
        pack = firmware_root / "pack" if (firmware_root / "pack").is_dir() else firmware_root
        names = {p.name for p in pack.iterdir() if p.is_file() and p.suffix.lower() in (".bin", ".rom", ".fd")}
        names.add(machine["firmware"]["file"])
        for name in sorted(names):
            source = firmware_root / "pack" / name
            if not source.is_file():
                source = firmware_root / name
            manifest["firmwareFiles"][name] = asset(root, source)
    if args.cache:
        cache = Path(args.cache)
        descriptor = cache / "transport.json" if cache.is_dir() else cache
        files = {path.relative_to(descriptor.parent).as_posix(): {"sha256": digest(path), "size": path.stat().st_size}
                 for path in sorted(descriptor.parent.rglob("*")) if path.is_file()}
        collection = hashlib.sha256(canonical(files)).hexdigest()
        destination = root / "assets" / collection
        shutil.copytree(descriptor.parent, destination, dirs_exist_ok=True)
        manifest["cacheTransport"] = {"url": f"../../assets/{collection}/{descriptor.name}", **files[descriptor.name]}
        manifest["cacheIdentity"] = {"sha256": collection, "files": files}
    if args.evaluator:
        evaluator = Path(args.evaluator)
        source = evaluator / "share/playground" if (evaluator / "share/playground").is_dir() else evaluator
        shutil.copytree(source, root / "playground", dirs_exist_ok=True)
        metadata = source / "wasm/build-metadata.json"
        if not metadata.is_file():
            raise ValueError("direct evaluator build metadata unavailable")
        manifest["evaluator"] = {
            "metadata": json.loads(metadata.read_bytes()),
            "artifacts": {path.relative_to(source).as_posix(): asset(root, path)
                          for path in sorted(source.rglob("*")) if path.is_file()},
        }
    manifest["runtimeRevision"] = runtime_identity(manifest)
    if args.snapshot:
        bundle = Path(args.snapshot)
        metadata = json.loads((bundle / "snapshot.json").read_bytes())
        if metadata.get("machineHash") != manifest["machineHash"] or metadata.get("machine") != machine:
            raise ValueError("snapshot machine contract mismatch")
        bindings = metadata.get("bindings", {})
        if (bindings.get("runtimeAssets") != assets or bindings.get("sourceRevision") != args.revision
                or bindings.get("runtimeRevision") != manifest["runtimeRevision"]):
            raise ValueError("snapshot runtime assets, source revision or runtime revision mismatch")
        if bindings.get("firmwareFiles", {}) != manifest.get("firmwareFiles", {}):
            raise ValueError("snapshot firmware pack identities mismatch")
        if metadata.get("compatibilityHash") != hashlib.sha256(canonical(bindings)).hexdigest():
            raise ValueError("snapshot compatibility hash mismatch")
        for role, record in metadata["artifacts"].items():
            if not safe_artifact_path(record.get("file")):
                raise ValueError(f"unsafe snapshot file path: {role}")
            relative = Path(record["file"])
            source = bundle / relative
            if digest(source) != record["sha256"] or source.stat().st_size != record["size"]:
                raise ValueError(f"snapshot {role} identity mismatch")
        descriptor = asset(root, bundle / "snapshot.json")
        destination = root / descriptor["url"].removeprefix("../../")
        for record in metadata["artifacts"].values():
            relative = Path(record["file"])
            target = destination.parent / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(bundle / relative, target)
        manifest["snapshot"] = descriptor
    notices = root / "licenses"
    notices.mkdir(exist_ok=True)
    notice_inputs = [("engine", args.engine), ("vendor", args.vendor), ("image", args.image)]
    if args.firmware_notices:
        notice_inputs.append(("firmware", args.firmware_notices))
    for label, directory in notice_inputs:
        directory = Path(directory)
        for pattern in ("*LICENSE*", "*COPYING*", "*NOTICE*", "*provenance*", "*source*", "*pins*", "*identity*", "licenses", "share/licenses"):
            for source in directory.glob(pattern):
                target = notices / label / source.name
                target.parent.mkdir(parents=True, exist_ok=True)
                if source.is_dir():
                    shutil.copytree(source, target, dirs_exist_ok=True)
                else:
                    shutil.copyfile(source, target)
    headers = root / "_headers"
    if headers.is_file():
        with headers.open("a") as stream:
            for directory in sorted((root / "assets").iterdir()):
                if directory.is_dir() and re.fullmatch(r"[a-f0-9]{64}", directory.name):
                    stream.write(f"\n/assets/{directory.name}/*\n  Cache-Control: public, max-age=31536000, immutable\n")
    # Runtime identities already bind compressed/raw disk, firmware, cache and
    # snapshot bytes. Hash only the remaining published frontend/notices here;
    # never walk assets and rehash the large disk or captured memory streams.
    payload = {}
    site_assets = Path(args.site) / "assets"
    if site_assets.is_dir():
        for path in sorted(site_assets.rglob("*")):
            if path.is_file():
                payload[(Path("assets") / path.relative_to(site_assets)).as_posix()] = {"sha256": digest(path), "size": path.stat().st_size}
    evaluator_files = manifest.get("evaluator", {}).get("artifacts", {})
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root)
        if not path.is_file() or relative.parts[0] in ("assets", "revisions"):
            continue
        pinned = evaluator_files.get(relative.as_posix().removeprefix("playground/")) if relative.parts[0] == "playground" else None
        payload[relative.as_posix()] = {"sha256": pinned["sha256"] if pinned else digest(path),
                                       "size": path.stat().st_size}
    manifest["payloadIdentity"] = {"sha256": hashlib.sha256(canonical(payload)).hexdigest(), "files": payload}
    manifest["assemblyRecipeSha256"] = digest(Path(__file__))
    # No self-hash recursion: revision is derived from the complete contract
    # before that one field is inserted. Provenance below is derived from it.
    manifest["revision"] = release_identity(manifest)
    revision = root / "revisions" / manifest["revision"]
    revision.mkdir(parents=True)
    write_json(revision / "manifest.json", manifest)
    write_json(root / "provenance.json", {
        "schemaVersion": 1, "revision": manifest["revision"], "sourceRevision": args.revision,
        "runtimeRevision": manifest["runtimeRevision"], "target": manifest["target"],
        "manifestHash": digest(revision / "manifest.json"),
        "inputIdentities": {key: manifest[key] for key in ("assets", "machineHash", "guestIdentity")},
        "capabilities": manifest["capabilities"],
        "publication": "Assets are assembled before channel.json; upload the complete tree atomically.",
    })
    # Keep frontend relative imports unchanged at both entrypoints, not asset copies.
    for source in list(root.iterdir()):
        if source.name in ("revisions", "assets", "manifest.json", "channel.json"):
            continue
        if source.is_dir():
            shutil.copytree(source, revision / source.name, copy_function=os.link)
        else:
            os.link(source, revision / source.name)
    # Original static frontend assets are small and belong to the saved frontend
    # revision. Do not copy the generated VM/disk asset tree into every release.
    if site_assets.is_dir():
        shutil.copytree(site_assets, revision / "assets", copy_function=shutil.copyfile)
    pointer = {
        "schemaVersion": 1, "revision": manifest["revision"], "sourceRevision": args.revision,
        "manifest": {"url": f"revisions/{manifest['revision']}/manifest.json",
                     "sha256": digest(revision / "manifest.json"),
                     "size": (revision / "manifest.json").stat().st_size},
    }
    write_json(root / "manifest.json", pointer)
    write_json(root / "channel.json", pointer)
    # Mutable /live/ never imports VM code. Preserve the immutable frontend above,
    # then remove its root hardlinks before installing the revision-neutral router.
    shutil.rmtree(root / "live")
    (root / "live").mkdir()
    (root / "live/index.html").write_text(BOOTSTRAP)


BOOTSTRAP = '''<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Selecting Redox browser revision</title>
<main><h1>Redox browser demo</h1><p id="status" role="status">Selecting the published immutable revision…</p>
<a href="../#demo">Return to the landing page and recordings</a></main>
<script>
(async () => {
  const status = document.getElementById('status');
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 15000);
  try {
    const base = new URL('../', location.href);
    const response = await fetch(new URL('channel.json', base), {cache:'no-store', signal:controller.signal});
    if (!response.ok) throw Error(`Channel unavailable: HTTP ${response.status}`);
    const pointer = await response.json();
    if (pointer.schemaVersion !== 1 || !/^[a-f0-9]{64}$/.test(pointer.revision) || typeof pointer.sourceRevision !== 'string'
        || pointer.manifest?.url !== `revisions/${pointer.revision}/manifest.json`
        || !/^[a-f0-9]{64}$/.test(pointer.manifest.sha256)
        || !Number.isSafeInteger(pointer.manifest.size) || pointer.manifest.size < 1 || pointer.manifest.size > 4194304) {
      throw Error('The published channel pointer is incompatible or malformed.');
    }
    const manifestResponse = await fetch(new URL(pointer.manifest.url, base), {cache:'no-store', signal:controller.signal});
    if (!manifestResponse.ok) throw Error(`Revision ${pointer.revision} artifacts unavailable: HTTP ${manifestResponse.status}`);
    if (!manifestResponse.body) throw Error('Revision manifest has no response body.');
    const bytes = new Uint8Array(pointer.manifest.size);
    const reader = manifestResponse.body.getReader();
    let offset = 0;
    try {
      while (true) {
        const {done,value} = await reader.read();
        if (done) break;
        if (offset + value.byteLength > bytes.byteLength) throw Error('Revision manifest exceeds its pinned transfer size.');
        bytes.set(value, offset);
        offset += value.byteLength;
      }
    } catch (error) { await reader.cancel().catch(()=>{}); throw error; }
    if (offset !== bytes.byteLength) throw Error('Revision manifest transfer size mismatch.');
    if (!globalThis.crypto?.subtle) throw Error('Manifest verification needs Web Crypto: use HTTPS or localhost.');
    const hash = [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))].map(x=>x.toString(16).padStart(2,'0')).join('');
    if (hash !== pointer.manifest.sha256) throw Error('Revision manifest SHA-256 mismatch.');
    const selected = JSON.parse(new TextDecoder('utf-8', {fatal:true}).decode(bytes));
    if (selected.revision !== pointer.revision || selected.sourceRevision !== pointer.sourceRevision) throw Error('Channel/source/bundle revision mismatch.');
    const target = new URL(`revisions/${pointer.revision}/live/`, base);
    target.search = location.search;
    target.hash = location.hash;
    location.replace(target.href);
  } catch (error) {
    status.textContent = `The live demo cannot select a verified revision: ${error.message}. Retry from the channel URL or use the recordings below.`;
    status.setAttribute('role', 'alert');
  } finally { clearTimeout(timer); }
})();
</script></html>
'''


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    for field in ("out", "site", "engine", "vendor", "image", "machine", "firmware", "revision"):
        p.add_argument("--" + field, required=True)
    for field in ("cache", "evaluator", "snapshot", "firmware-notices", "disk-chunker"):
        p.add_argument("--" + field)
    return p


if __name__ == "__main__":
    assemble(parser().parse_args())
