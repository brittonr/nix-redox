#!/usr/bin/env python3
"""
Build a Nix-compatible binary cache from cross-compiled packages.

Generates:
  nix-cache-info          — cache metadata
  packages.json           — v2 installable-root index (non-standard, for snix)
  {hash}.narinfo          — per-path metadata
  nar/{sha256hex}.nar.zst — compressed NAR files
  closure.json            — v1 complete closure with direct references/evidence
  transport.json          — v1 exact per-root transport inventory

NAR format: https://nixos.org/manual/nix/stable/protocols/nix-archive
"""

import base64
import hashlib
import json
import os
import re
import struct
import subprocess
import sys
import tempfile


# ─── Nixbase32 Encoding ────────────────────────────────────────────────────

NIX_CHARS = "0123456789abcdfghijklmnpqrsvwxyz"

def nixbase32_encode(data: bytes) -> str:
    """Encode bytes to nixbase32 (Nix's custom base32 alphabet).

    Nix processes bytes in reverse order and packs 5 bits per character.
    For 32 bytes (SHA-256), produces 52 characters.
    """
    n_chars = (len(data) * 8 + 4) // 5
    result = []
    for i in range(n_chars - 1, -1, -1):
        bit_offset = i * 5
        byte_idx = bit_offset // 8
        bit_idx = bit_offset % 8
        val = (data[byte_idx] >> bit_idx) & 0x1F
        if bit_idx > 3 and byte_idx + 1 < len(data):
            val |= (data[byte_idx + 1] << (8 - bit_idx)) & 0x1F
        result.append(NIX_CHARS[val])
    return "".join(result)


# ─── NAR Serializer ────────────────────────────────────────────────────────

def _write_str(f, s):
    """Write a NAR string: 8-byte LE length + content + padding to 8 bytes."""
    b = s.encode("utf-8") if isinstance(s, str) else s
    f.write(struct.pack("<Q", len(b)))
    f.write(b)
    pad = (8 - (len(b) % 8)) % 8
    if pad:
        f.write(b"\x00" * pad)


def _serialize_entry(f, path):
    """Recursively serialize one filesystem entry to NAR."""
    _write_str(f, "(")
    _write_str(f, "type")

    if os.path.islink(path):
        _write_str(f, "symlink")
        _write_str(f, "target")
        target = os.readlink(path)
        _write_str(f, target if isinstance(target, bytes) else target.encode("utf-8"))

    elif os.path.isdir(path):
        _write_str(f, "directory")
        for name in sorted(os.listdir(os.fsencode(path))):
            _write_str(f, "entry")
            _write_str(f, "(")
            _write_str(f, "name")
            _write_str(f, name)
            _write_str(f, "node")
            _serialize_entry(f, os.path.join(os.fsencode(path), name))
            _write_str(f, ")")

    elif os.path.isfile(path):
        _write_str(f, "regular")
        if os.access(path, os.X_OK):
            _write_str(f, "executable")
            _write_str(f, "")
        _write_str(f, "contents")
        size = os.path.getsize(path)
        f.write(struct.pack("<Q", size))
        with open(path, "rb") as fh:
            while True:
                chunk = fh.read(65536)
                if not chunk:
                    break
                f.write(chunk)
        pad = (8 - (size % 8)) % 8
        if pad:
            f.write(b"\x00" * pad)
    else:
        raise ValueError(f"Unsupported file type: {path}")

    _write_str(f, ")")


def serialize_to_nar(store_path, output_path):
    """Serialize a store path to a NAR file. Returns (nar_hash_bytes, nar_size)."""
    hasher = hashlib.sha256()
    size = 0

    with open(output_path, "wb") as f:
        class HashingWriter:
            def write(self, data):
                nonlocal size
                hasher.update(data)
                size += len(data)
                f.write(data)

        hw = HashingWriter()
        _write_str(hw, "nix-archive-1")
        _serialize_entry(hw, store_path)

    return hasher.digest(), size


# ─── Binary Cache Builder ──────────────────────────────────────────────────

def store_path_hash(path):
    """Extract the nixbase32 hash from a store path.
    /nix/store/{hash}-{name} → {hash} (32 chars)
    """
    basename = os.path.basename(path)
    return basename[:32]


def store_path_name(path):
    """Extract the name from a store path.
    /nix/store/{hash}-{name} → {name}
    """
    basename = os.path.basename(path)
    return basename[33:]  # skip hash + dash


def build_narinfo(store_path, nar_hash_bytes, nar_size, file_hash_bytes, file_size, nar_url,
                  references):
    """Generate a narinfo file content.

    Uses nixbase32 for hashes (the canonical format for Nix binary caches).
    """
    nar_hash_nix32 = nixbase32_encode(nar_hash_bytes)
    file_hash_nix32 = nixbase32_encode(file_hash_bytes)
    lines = [
        f"StorePath: {store_path}",
        f"URL: {nar_url}",
        f"Compression: zstd",
        f"FileHash: sha256:{file_hash_nix32}",
        f"FileSize: {file_size}",
        f"NarHash: sha256:{nar_hash_nix32}",
        f"NarSize: {nar_size}",
        "References: " + " ".join(os.path.basename(ref) for ref in sorted(set(references))),
    ]
    return "\n".join(lines) + "\n"


STORE_PATH = re.compile(r"/nix/store/[0123456789abcdfghijklmnpqrsvwxyz]{32}-[^/\s]+\Z")


def compatibility_for(path, declaration, target):
    """Inspect content, never names or the platform that assembled a data file.

    ELF executable/shared-object content needs declared build-target evidence.
    ELF headers cannot distinguish all Linux and Redox binaries (both use SYSV
    OSABI), so guessing from those headers would incorrectly certify host code.
    Host-assembled data and shebang scripts do not need a native-code target.
    Their store references, including store-path interpreters, remain in closure.
    """
    native = False
    script = False
    paths = []
    if os.path.isdir(path) and not os.path.islink(path):
        for directory, dirs, files in os.walk(path, followlinks=False):
            dirs.sort()
            paths.extend(os.path.join(directory, name) for name in sorted(files))
    else:
        paths.append(path)
    for item in paths:
        if os.path.islink(item):
            continue  # The referent is checked as its own graph member.
        with open(item, "rb") as stream:
            header = stream.read(64)
        if header.startswith(b"\x7fELF"):
            if len(header) < 20 or header[5] not in (1, 2):
                raise ValueError(f"invalid ELF header: {item}")
            endian = "little" if header[5] == 1 else "big"
            if int.from_bytes(header[16:18], endian) in (2, 3):
                native = True
                # This cache's declared ABI is x86_64, not merely any Redox.
                if target == "x86_64-unknown-redox" and (
                    header[4] != 2 or int.from_bytes(header[18:20], endian) != 62
                ):
                    raise ValueError(f"wrong-target ELF architecture: {item}")
        elif header[:4] in (b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
                            b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe"):
            raise ValueError(f"wrong-target native executable: {item}")
        elif header.startswith(b"MZ") and len(header) >= 64:
            # A two-byte text prefix is not executable evidence. PE requires
            # the DOS header's offset to name an actual PE signature.
            with open(item, "rb") as stream:
                stream.seek(int.from_bytes(header[60:64], "little"))
                if stream.read(4) == b"PE\x00\x00":
                    raise ValueError(f"wrong-target native executable: {item}")
        elif header.startswith(b"#!"):
            script = True
    if native:
        if not declaration or not isinstance(declaration.get("evidence"), str) or not declaration["evidence"]:
            raise ValueError(f"native code in {path} lacks declared target evidence; add pathMetadata")
        if declaration.get("target") != target:
            raise ValueError(f"wrong-target native code in {path}: declared {declaration.get('target')!r}, expected {target}")
        return {"version": 1, "kind": "native", "target": target,
                "evidence": declaration["evidence"]}
    return {"version": 1, "kind": "script" if script else "data", "target": "any",
            "evidence": "content:shebang-no-native-code" if script else "content:no-native-code"}


def validate_manifest(info, exists=os.path.lexists, inspect=compatibility_for):
    """Validate the Nix-supplied closure before producing any successful index."""
    target = info["target"]
    if target != "x86_64-unknown-redox":
        raise ValueError(f"unsupported guest cache target: {target}")
    members = {}
    for entry in info["closure"]:
        path = entry["path"]
        if not STORE_PATH.fullmatch(path):
            raise ValueError(f"invalid store path in closure: {path}")
        if path in members:
            raise ValueError(f"duplicate closure member: {path}")
        members[path] = {"references": sorted(set(entry["references"]))}
    roots = {}
    declarations = {}
    for entry in info.get("pathMetadata", []):
        path = entry["path"]
        declaration = {"target": entry["target"], "evidence": entry["evidence"]}
        if path in declarations and declarations[path] != declaration:
            raise ValueError(f"conflicting target evidence for {path}")
        declarations[path] = declaration
    for entry in info["packageEntries"]:
        name, path = entry["name"], entry["storePath"]
        if name in roots:
            raise ValueError(f"duplicate package name: {name}")
        if path not in members:
            raise ValueError(f"installable root {name} missing from closure: {path}")
        roots[name] = path
        declaration = entry.get("compatibility")
        # An explicit per-path declaration may describe a manually cross-built
        # output whose stdenv itself still describes the host builder.
        if declaration and path not in declarations:
            declarations[path] = declaration
    for path, member in sorted(members.items()):
        if not exists(path):
            raise ValueError(f"missing dependency payload: {path}")
        for reference in member["references"]:
            if reference not in members:
                raise ValueError(f"unresolved reference: {path} -> {reference}")
        member["compatibility"] = inspect(path, declarations.get(path), target)
    # Check reachability iteratively: diamond, self and cyclic references are
    # retained truthfully and cannot recurse forever or duplicate payloads.
    reached, pending = set(), list(roots.values())
    while pending:
        path = pending.pop()
        if path not in reached:
            reached.add(path)
            pending.extend(members[path]["references"])
    if reached != members.keys():
        raise ValueError(f"unreachable closure members: {sorted(members.keys() - reached)}")
    return {"version": 1, "target": target, "roots": dict(sorted(roots.items())),
            "paths": dict(sorted(members.items()))}


def verify_registered_nar(entry, digest, size):
    """The output's identity stays Nix's identity; verify our NAR against it."""
    known_hash = entry["narHash"]
    accepted = {"sha256:" + nixbase32_encode(digest), "sha256:" + digest.hex(),
                "sha256-" + base64.b64encode(digest).decode("ascii")}
    if known_hash not in accepted or entry["narSize"] != size:
        raise ValueError(f"NAR differs from Nix registration for {entry['path']}: {known_hash}")


def build_transport(manifest, out_dir):
    """Pin the exact metadata and payload bytes needed for each selected root."""
    inventory = {}

    def record(relative):
        if relative not in inventory:
            digest, size = hashlib.sha256(), 0
            with open(os.path.join(out_dir, relative), "rb") as stream:
                for chunk in iter(lambda: stream.read(65536), b""):
                    digest.update(chunk)
                    size += len(chunk)
            inventory[relative] = {"path": relative, "sha256": digest.hexdigest(), "size": size}
        return inventory[relative]

    packages = {}
    for name, root in manifest["roots"].items():
        reached, pending = set(), [root]
        files = {"packages.json", "closure.json", "nix-cache-info"}
        while pending:
            path = pending.pop()
            if path in reached:
                continue
            reached.add(path)
            member = manifest["paths"][path]
            pending.extend(member["references"])
            files.add(f"{store_path_hash(path)}.narinfo")
            files.add(member["url"])
        packages[name] = {"storePath": root, "files": [record(path) for path in sorted(files)]}
    transport = {"version": 1, "target": manifest["target"], "packages": packages}
    with open(os.path.join(out_dir, "transport.json"), "w") as stream:
        json.dump(transport, stream, indent=2, sort_keys=True)
        stream.write("\n")


def build_cache(info, out_dir):
    manifest = validate_manifest(info)
    os.makedirs(os.path.join(out_dir, "nar"), exist_ok=True)
    index = {"version": 2, "closureManifestVersion": 1,
             "installationMode": "recursive", "packages": {}}
    registered = {entry["path"]: entry for entry in info["closure"]}
    total_nar = total_compressed = 0
    for store_path, member in manifest["paths"].items():
        print(f"  NAR-serializing {store_path}...", file=sys.stderr)
        with tempfile.NamedTemporaryFile(suffix=".nar", delete=False) as tmp:
            tmp_nar = tmp.name
        try:
            nar_hash_bytes, nar_size = serialize_to_nar(store_path, tmp_nar)
            verify_registered_nar(registered[store_path], nar_hash_bytes, nar_size)
            total_nar += nar_size
            compressed_name = f"{nar_hash_bytes.hex()}.nar.zst"
            compressed_path = os.path.join(out_dir, "nar", compressed_name)
            subprocess.run(["zstd", "-q", "-19", "-f", "--rm", tmp_nar,
                            "-o", compressed_path], check=True)
            file_hasher, file_size = hashlib.sha256(), 0
            with open(compressed_path, "rb") as stream:
                for chunk in iter(lambda: stream.read(65536), b""):
                    file_hasher.update(chunk)
                    file_size += len(chunk)
            total_compressed += file_size
            nar_url = f"nar/{compressed_name}"
            narinfo = build_narinfo(store_path, nar_hash_bytes, nar_size,
                                   file_hasher.digest(), file_size, nar_url,
                                   member["references"])
            with open(os.path.join(out_dir, f"{store_path_hash(store_path)}.narinfo"), "w") as stream:
                stream.write(narinfo)
            member.update({"narHash": f"sha256:{nar_hash_bytes.hex()}",
                           "narSize": nar_size, "fileSize": file_size, "url": nar_url})
        finally:
            if os.path.exists(tmp_nar):
                os.unlink(tmp_nar)
    # All graph members have verified payloads before any installable roots are
    # advertised. Internal dependencies are intentionally not separate products.
    for entry in sorted(info["packageEntries"], key=lambda item: item["name"]):
        member = manifest["paths"][entry["storePath"]]
        index["packages"][entry["name"]] = {
            "storePath": entry["storePath"], "pname": entry["pname"],
            "version": entry["version"],
            **{key: member[key] for key in ("narHash", "narSize", "fileSize", "compatibility")},
        }
    for filename, value in (("closure.json", manifest), ("packages.json", index)):
        with open(os.path.join(out_dir, filename), "w") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
    with open(os.path.join(out_dir, "nix-cache-info"), "w") as stream:
        stream.write("StoreDir: /nix/store\n")
    build_transport(manifest, out_dir)
    print(f"Binary cache: {len(index['packages'])} roots, {len(manifest['paths'])} paths; "
          f"{total_nar} NAR bytes, {total_compressed} compressed bytes", file=sys.stderr)


def main():
    if len(sys.argv) != 3:
        sys.exit(f"Usage: {sys.argv[0]} <nix-attrs.json> <output-dir>")
    with open(sys.argv[1]) as stream:
        info = json.load(stream)
    try:
        build_cache(info, sys.argv[2])
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"binary-cache export failed: {error}")


if __name__ == "__main__":
    main()
