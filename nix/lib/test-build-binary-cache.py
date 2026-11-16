#!/usr/bin/env python3
"""Consumer-visible cache graph/evidence and NAR registration contracts."""
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("cache_builder", os.environ.get("CACHE_BUILDER", Path(__file__).with_name("build-binary-cache.py")))
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)
TARGET = "x86_64-unknown-redox"
A = "/nix/store/" + "a" * 32 + "-a"
B = "/nix/store/" + "b" * 32 + "-b"
C = "/nix/store/" + "c" * 32 + "-c"
D = "/nix/store/" + "d" * 32 + "-d"


def graph(edges):
    return {"target": TARGET, "packageEntries": [{"name": "a", "storePath": A,
             "pname": "a", "version": "1"}], "closure": [
        {"path": path, "references": refs} for path, refs in edges.items()]}


def data_evidence(path, declaration, target):
    return {"version": 1, "kind": "data", "target": "any", "evidence": "unit-graph"}


class CacheContracts(unittest.TestCase):
    def manifest(self, edges):
        # The Nix integration test covers real store payloads. These pure graph
        # tests isolate graph invariants without creating host store objects.
        return builder.validate_manifest(graph(edges), exists=lambda _: True, inspect=data_evidence)

    def test_chain_exports_all_paths_and_direct_references(self):
        manifest = self.manifest({A: [B], B: [C], C: []})
        self.assertEqual(list(manifest["paths"]), [A, B, C])
        self.assertEqual(manifest["roots"], {"a": A})
        self.assertEqual(manifest["paths"][A]["references"], [B])
        self.assertEqual(manifest["paths"][B]["references"], [C])

    def test_diamond_self_and_input_order_are_deterministic(self):
        edges = {A: [C, B, A, B], C: [D], B: [D], D: []}
        first = self.manifest(edges)
        second = self.manifest(dict(reversed(list(edges.items()))))
        self.assertEqual(first, second)
        self.assertEqual(first["paths"][A]["references"], [A, B, C])
        self.assertEqual(len(first["paths"]), 4)
        narinfo = builder.build_narinfo(A, b"a" * 32, 1, b"b" * 32, 1,
                                      "nar/a.nar.zst", edges[A])
        expected = "References: " + " ".join(Path(p).name for p in [A, B, C])
        self.assertIn(expected + "\n", narinfo)

    def test_missing_reference_fails(self):
        with self.assertRaisesRegex(ValueError, "unresolved reference"):
            self.manifest({A: [B]})

    def test_missing_payload_fails_instead_of_skipping(self):
        with self.assertRaisesRegex(ValueError, "missing dependency payload"):
            builder.validate_manifest(graph({A: []}), exists=lambda _: False)

    def test_root_must_belong_to_closure(self):
        with self.assertRaisesRegex(ValueError, "root a missing from closure"):
            self.manifest({B: []})

    def test_unreachable_members_fail(self):
        with self.assertRaisesRegex(ValueError, "unreachable closure members"):
            self.manifest({A: [], B: []})

    def test_wrong_target_uses_evidence_not_name(self):
        with tempfile.TemporaryDirectory(prefix="looks-like-redox-") as tmp:
            native = Path(tmp) / "guest-redox"
            # A native-format header exercises ABI classification; no fixture
            # is represented as a runnable Redox executable by this unit test.
            header = bytearray(64)
            header[:6] = b"\x7fELF\x02\x01"
            header[16:20] = b"\x02\x00\x3e\x00"
            native.write_bytes(header)
            with self.assertRaisesRegex(ValueError, "wrong-target native code"):
                builder.compatibility_for(str(native), {"target": "x86_64-linux", "evidence": "stdenv.hostPlatform"}, TARGET)
            with self.assertRaisesRegex(ValueError, "lacks declared target evidence"):
                builder.compatibility_for(str(native), None, TARGET)
            native.write_text("host-assembled runtime data")
            self.assertEqual(builder.compatibility_for(str(native), {"target": "x86_64-linux", "evidence": "builder"}, TARGET)["kind"], "data")
            native.write_text("#!/bin/sh\necho guest-script\n")
            self.assertEqual(builder.compatibility_for(str(native), {"target": "x86_64-linux", "evidence": "builder"}, TARGET)["kind"], "script")

    def test_text_prefix_is_not_native_executable_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            payload = Path(tmp) / "runtime-data"
            payload.write_bytes(b"MZ" + b"data" * 32)
            self.assertEqual(builder.compatibility_for(str(payload), None, TARGET)["kind"], "data")
            header = bytearray(64)
            header[:2] = b"MZ"
            header[60:64] = (64).to_bytes(4, "little")
            payload.write_bytes(header + b"PE\x00\x00")
            with self.assertRaisesRegex(ValueError, "wrong-target native executable"):
                builder.compatibility_for(str(payload), None, TARGET)

    def test_wrong_target_dependency_fails_without_filtering(self):
        with tempfile.TemporaryDirectory() as tmp:
            payloads = {A: Path(tmp) / "data", B: Path(tmp) / "looks-like-redox"}
            payloads[A].write_text("runtime data")
            shutil.copyfile(sys.executable, payloads[B])
            info = graph({A: [B], B: []})
            info["pathMetadata"] = [{"path": B, "target": "x86_64-unknown-linux-gnu",
                                     "evidence": "test:host-python-interpreter"}]
            def inspect(path, declaration, target):
                return builder.compatibility_for(str(payloads[path]), declaration, target)
            with self.assertRaisesRegex(ValueError, "wrong-target native code"):
                builder.validate_manifest(info, exists=lambda p: payloads[p].exists(), inspect=inspect)

    def test_registered_identity_hash_and_size_are_preserved(self):
        digest = hashlib.sha256(b"nar").digest()
        entry = {"path": A, "narHash": "sha256:" + builder.nixbase32_encode(digest), "narSize": 3}
        builder.verify_registered_nar(entry, digest, 3)
        with self.assertRaisesRegex(ValueError, "NAR differs from Nix registration"):
            builder.verify_registered_nar(entry, hashlib.sha256(b"other").digest(), 3)
        with self.assertRaisesRegex(ValueError, "NAR differs from Nix registration"):
            builder.verify_registered_nar(entry, digest, 4)


if __name__ == "__main__":
    unittest.main()
