#!/usr/bin/env python3
"""
Build a Nix-compatible binary cache from cross-compiled packages.

Generates:
  nix-cache-info          — cache metadata
  packages.json           — name → store path index (non-standard, for snix)
  {hash}.narinfo          — per-path metadata
  nar/{sha256hex}.nar.zst — compressed NAR files

NAR format: https://nixos.org/manual/nix/stable/protocols/nix-archive
"""

import hashlib
import json
import os
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
        for name in sorted(os.listdir(path)):
            _write_str(f, "entry")
            _write_str(f, "(")
            _write_str(f, "name")
            _write_str(f, name)
            _write_str(f, "node")
            _serialize_entry(f, os.path.join(path, name))
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


def build_narinfo(store_path, nar_hash_bytes, nar_size, file_hash_bytes, file_size, nar_url):
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
        f"References: ",
    ]
    return "\n".join(lines) + "\n"


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <package-info.json> <output-dir>", file=sys.stderr)
        sys.exit(1)

    info_path = sys.argv[1]
    out_dir = sys.argv[2]

    with open(info_path) as f:
        package_list = json.load(f)

    os.makedirs(os.path.join(out_dir, "nar"), exist_ok=True)

    # Build index for packages.json
    index = {"version": 1, "packages": {}}
    total_nar = 0
    total_compressed = 0

    for entry in package_list:
        name = entry["name"]
        store_path = entry["storePath"]
        pname = entry.get("pname", name)
        version = entry.get("version", "unknown")

        if not os.path.exists(store_path):
            print(f"  SKIP {name}: {store_path} not found", file=sys.stderr)
            continue

        sp_hash = store_path_hash(store_path)
        print(f"  {name}: NAR-serializing {store_path}...", file=sys.stderr)

        # 1. Serialize to NAR (temp file)
        with tempfile.NamedTemporaryFile(suffix=".nar", delete=False) as tmp:
            tmp_nar = tmp.name

        try:
            nar_hash_bytes, nar_size = serialize_to_nar(store_path, tmp_nar)
            nar_hash_hex = nar_hash_bytes.hex()
            total_nar += nar_size

            # 2. Compress with zstd
            compressed_name = f"{nar_hash_hex}.nar.zst"
            compressed_path = os.path.join(out_dir, "nar", compressed_name)

            subprocess.run(
                ["zstd", "-q", "-19", "--rm", tmp_nar, "-o", compressed_path],
                check=True,
            )

            # 3. Hash the compressed file
            file_hasher = hashlib.sha256()
            file_size = 0
            with open(compressed_path, "rb") as cf:
                while True:
                    chunk = cf.read(65536)
                    if not chunk:
                        break
                    file_hasher.update(chunk)
                    file_size += len(chunk)
            file_hash_bytes = file_hasher.digest()
            total_compressed += file_size

            # 4. Write narinfo
            nar_url = f"nar/{compressed_name}"
            narinfo_content = build_narinfo(
                store_path, nar_hash_bytes, nar_size, file_hash_bytes, file_size, nar_url
            )
            narinfo_path = os.path.join(out_dir, f"{sp_hash}.narinfo")
            with open(narinfo_path, "w") as nf:
                nf.write(narinfo_content)

            # 5. Add to index
            index["packages"][name] = {
                "storePath": store_path,
                "pname": pname,
                "version": version,
                "narHash": f"sha256:{nar_hash_hex}",
                "narSize": nar_size,
                "fileSize": file_size,
            }

            ratio = (file_size / nar_size * 100) if nar_size > 0 else 0
            print(
                f"         NAR {nar_size // 1024}K → zstd {file_size // 1024}K ({ratio:.0f}%)",
                file=sys.stderr,
            )

        finally:
            if os.path.exists(tmp_nar):
                os.unlink(tmp_nar)

    # Write packages.json index
    with open(os.path.join(out_dir, "packages.json"), "w") as f:
        json.dump(index, f, indent=2, sort_keys=True)

    # Write nix-cache-info
    with open(os.path.join(out_dir, "nix-cache-info"), "w") as f:
        f.write("StoreDir: /nix/store\n")

    pkg_count = len(index["packages"])
    print(file=sys.stderr)
    print(f"Binary cache: {pkg_count} packages", file=sys.stderr)
    print(f"  Total NAR:        {total_nar // (1024*1024)} MB", file=sys.stderr)
    print(f"  Total compressed: {total_compressed // (1024*1024)} MB", file=sys.stderr)


if __name__ == "__main__":
    main()
