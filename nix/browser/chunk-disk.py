#!/usr/bin/env python3
"""Export a raw disk without altering its GPT/ESP/RedoxFS bytes.

Usage: chunk-disk.py IMAGE OUTPUT [--chunk-size 1048576]
OUTPUT/manifest.json is deterministic; chunks/<sha256> contains nonzero objects.
Publish the entire directory immutably and pin manifest.json's SHA-256 in the
browser artifact manifest. The source raw image remains the preload reference.
"""
import argparse
import hashlib
import json
from pathlib import Path


def export(image, output, chunk_size=1048576):
    image, output = Path(image), Path(output)
    if chunk_size < 512 or chunk_size % 512 or chunk_size > 16777216:
        raise ValueError("chunk size must be a sector multiple in [512, 16777216]")
    size = image.stat().st_size
    if not size or size % 512 or size > 2**53 - 1:
        raise ValueError("disk must have a positive, JS-safe, sector-aligned size")
    output.mkdir(parents=True, exist_ok=True)
    objects = output / "chunks"
    objects.mkdir(exist_ok=True)
    chunks, identity = [], hashlib.sha256()
    with image.open("rb") as source:
        while data := source.read(chunk_size):
            identity.update(data)
            digest = hashlib.sha256(data).hexdigest()
            zero = not any(data)
            entry = {"length": len(data), "sha256": digest, "zero": zero}
            if not zero:
                entry["url"] = f"chunks/{digest}"
                path = objects / digest
                if path.exists():
                    if path.read_bytes() != data:
                        raise ValueError(f"existing chunk does not match {digest}")
                else:
                    path.write_bytes(data)
            chunks.append(entry)
    if sum(c["length"] for c in chunks) != size:
        raise ValueError("source changed size during export")
    manifest = {"schemaVersion": 1, "format": "redox-chunk-disk-v1",
                "logicalSize": size, "sectorSize": 512, "chunkSize": chunk_size,
                "imageSha256": identity.hexdigest(), "chunks": chunks}
    encoded = (json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n").encode()
    (output / "manifest.json").write_bytes(encoded)
    return {"sha256": hashlib.sha256(encoded).hexdigest(), "size": len(encoded),
            "imageSha256": manifest["imageSha256"]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image")
    parser.add_argument("output")
    parser.add_argument("--chunk-size", type=int, default=1048576)
    args = parser.parse_args()
    print(json.dumps(export(args.image, args.output, args.chunk_size), sort_keys=True))
