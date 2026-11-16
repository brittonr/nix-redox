#!/usr/bin/env python3
"""Validate the exact browser-demo serial contract; usable by either VMM runner."""
import argparse
import json
from pathlib import Path
import re
import sys


def validate(catalog, serial, token=None):
    # QEMU and browser serial ports may produce CRLF. Never match echoed command
    # text, substrings of prompts, duplicate results, skipped tests or no output.
    lines = serial.replace("\r", "").splitlines()
    errors = []
    ready = catalog["readinessMarker"]
    if lines.count(ready) != 1:
        errors.append("expected exactly one strong readiness marker")
    if catalog["notReadyMarker"] in lines:
        errors.append("guest reported not ready")
    starts = [i for i, line in enumerate(lines) if line == catalog["suiteStart"]]
    ends = [i for i, line in enumerate(lines) if line == catalog["suiteComplete"]]
    if len(starts) != 1 or len(ends) != 1 or starts[0] >= ends[0]:
        errors.append("expected one ordered, complete test suite")
        return errors
    start, end = starts[0], ends[0]
    if ready in lines and lines.index(ready) >= start:
        errors.append("readiness must precede the suite")
    prefix = catalog["testPrefix"] + ":"
    records = [line for line in lines[start + 1:end] if line.startswith(prefix)]
    expected = [f"{prefix}{name}:PASS" for name in catalog["tests"]]
    if records != expected:
        errors.append("test results must exactly match the ordered PASS catalog")
    if any(line.startswith(prefix) for line in lines[:start] + lines[end + 1:]):
        errors.append("test result outside suite")
    if token is not None:
        if re.fullmatch(catalog["completion"]["tokenPattern"], token) is None:
            errors.append("invalid caller token")
        completion = f"REDOX_BROWSER_DEMO_COMMAND:{token}:0"
        matching = [i for i, line in enumerate(lines)
                    if line.startswith(f"REDOX_BROWSER_DEMO_COMMAND:{token}:")]
        if len(matching) != 1 or lines[matching[0]] != completion or matching[0] <= end:
            errors.append("missing unique successful command completion after suite")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path,
                        default=Path(__file__).with_name("catalog.json"))
    parser.add_argument("--serial", type=Path, required=True)
    parser.add_argument("--token")
    args = parser.parse_args()
    catalog = json.loads(args.catalog.read_text())
    errors = validate(catalog, args.serial.read_text(errors="replace"), args.token)
    print(json.dumps({"schemaVersion": 1, "passed": not errors, "errors": errors}))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
