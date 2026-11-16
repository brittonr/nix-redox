#!/usr/bin/env python3
"""Exercise autoboot patching against the real pinned upstream source.

Usage: python3 test-bootloader-autoboot.py /path/to/bootloader-src
No VM behavior is inferred by these source-transformation tests.
"""

from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest


SOURCE = Path(sys.argv.pop(1))
PATCH = (
    Path(__file__).resolve().parents[1]
    / "pkgs/system/patches/bootloader/patch-bootloader-autoboot.py"
)
MAIN_TARGET = '    println!();\n\n    println!("Arrow keys and enter select mode");'
CARGO_TARGET = "serial_debug = []"


class AutobootPatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "src").mkdir()
        self.original = {
            relative: (SOURCE / relative).read_bytes()
            for relative in ("src/main.rs", "Cargo.toml")
        }
        for relative, content in self.original.items():
            (self.root / relative).write_bytes(content)

    def patch(self):
        return subprocess.run(
            [sys.executable, str(PATCH), str(self.root)],
            capture_output=True,
            text=True,
            check=False,
        )

    def snapshot(self):
        return {relative: (self.root / relative).read_bytes() for relative in self.original}

    def test_autoboot_does_not_enable_live(self):
        result = self.patch()
        self.assertEqual(result.returncode, 0, result.stderr)
        cargo = (self.root / "Cargo.toml").read_text()
        self.assertEqual(tomllib.loads(cargo)["features"]["autoboot"], [])
        self.assertEqual(tomllib.loads(cargo)["features"]["live"], [])
        self.assertEqual(tomllib.loads(cargo)["features"]["default"], [])

    def test_missing_and_duplicate_targets_fail_without_any_writes(self):
        for relative, target in (("src/main.rs", MAIN_TARGET), ("Cargo.toml", CARGO_TARGET)):
            for occurrences in (0, 2):
                with self.subTest(file=relative, occurrences=occurrences):
                    for filename, content in self.original.items():
                        (self.root / filename).write_bytes(content)
                    path = self.root / relative
                    content = path.read_text()
                    self.assertEqual(content.count(target), 1, "pinned upstream target drifted")
                    path.write_text(content.replace(target, target * occurrences, 1))
                    before = self.snapshot()
                    result = self.patch()
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(self.snapshot(), before)

    def test_second_application_fails_without_any_writes(self):
        self.assertEqual(self.patch().returncode, 0)
        before = self.snapshot()
        self.assertNotEqual(self.patch().returncode, 0)
        self.assertEqual(self.snapshot(), before)


if __name__ == "__main__":
    unittest.main()
