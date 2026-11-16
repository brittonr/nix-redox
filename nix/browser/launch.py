#!/usr/bin/env python3
"""Matched native cold-boot proof; all launch topology comes from machine.json."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import secrets
import shutil
import socket
import subprocess
import sys
import threading
import time

READY = "REDOX_BROWSER_DEMO_READY:v1:shell=1:snix=1:initial=1"
ENGINE_FILES = {"engine": "out.js", "wasm": "qemu-system-x86_64.wasm", "worker": "qemu-system-x86_64.worker.js"}


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def identity(path):
    digest = hashlib.sha256()
    size = 0
    with open(path, "rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
            size += len(chunk)
    return {"sha256": digest.hexdigest(), "size": size}


def load(path):
    return json.loads(Path(path).read_text())


def save(path, value):
    Path(path).write_text(json.dumps(value, indent=2) + "\n")


def check_file(path, expected, label):
    actual = identity(path)
    if any(actual[key] != expected[key] for key in ("sha256", "size")):
        raise ValueError(f"{label} artifact mismatch: {path}")
    return actual


def configuration(args):
    manifest = load(args.manifest)
    if manifest.get("schemaVersion") != 1:
        raise ValueError("unsupported runtime manifest schema")
    machine = manifest["machine"]
    machine_hash = hashlib.sha256(canonical(machine)).hexdigest()
    if machine_hash != manifest["machineHash"]:
        raise ValueError("machineHash mismatch")
    if machine.get("firmware", {}).get("mode") != "bios" or machine["firmware"].get("mutable") != []:
        raise ValueError("only manifest-declared -bios firmware without mutable pflash is supported")
    assets = manifest["assets"]
    disk = assets["disk"]
    expected_disk = {"sha256": disk["rawSha256"], "size": disk["logicalSize"]} if disk.get("encoding") == "gzip" else disk
    check_file(args.disk, expected_disk, "raw disk")
    check_file(Path(args.pack) / machine["firmware"]["file"], assets["firmware"], "firmware")
    for filename, artifact in manifest.get("firmwareFiles", {}).items():
        relative = Path(filename)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("unsafe firmware pack path")
        check_file(Path(args.pack) / relative, artifact, f"firmware ROM {filename}")
    for role, filename in ENGINE_FILES.items():
        check_file(Path(args.engine_dir) / filename, assets[role], role)
    provenance = load(args.native_provenance)
    native = check_file(args.qemu, provenance["executable"], "native engine")
    pins = load(Path(__file__).with_name("engine-pins.json"))
    if provenance["qemuRevision"] != pins["qemuRevision"] or provenance["trynixRevision"] != pins["trynixRevision"]:
        raise ValueError("native engine source revision mismatch")
    if provenance.get("genericHostTicks") is not True:
        raise ValueError("native engine lacks matched generic host ticks")
    return manifest, native, provenance


class VM:
    def __init__(self, args, manifest, out):
        self.args = args
        self.out = Path(out)
        self.started = time.monotonic()
        self.lines = queue.Queue()
        disk = self.out / "running.raw"
        shutil.copyfile(args.disk, disk)
        disk.chmod(0o600)
        substitutions = {"pack": str(Path(args.pack).resolve()), "disk": str(disk.resolve()), "ram": manifest["machine"]["ram"]}
        self.command = [str(Path(args.qemu).resolve()), *(part.format(**substitutions) for part in manifest["machine"]["args"])]
        self.qmp_path = str((self.out / "qmp.sock").resolve())
        self.command += ["-qmp", f"unix:{self.qmp_path},server=on,wait=off"]
        self.stderr = (self.out / "qemu.stderr.log").open("wb")
        self.serial = (self.out / "serial.log").open("wb")
        save(self.out / "args.json", self.command)
        self.process = subprocess.Popen(self.command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr, bufsize=0)
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()
        self.sock = None
        self.qmp_file = None
        self.qmp_id = 0
        self.qmp_log = (self.out / "qmp.jsonl").open("w")

    def _read(self):
        pending = bytearray()
        while data := self.process.stdout.read(4096):
            self.serial.write(data)
            self.serial.flush()
            pending.extend(data)
            while b"\n" in pending:
                line, _, pending = pending.partition(b"\n")
                self.lines.put(line.decode(errors="replace").strip("\r"))
        if pending:
            self.lines.put(pending.decode(errors="replace").strip("\r"))

    def send(self, text):
        self.process.stdin.write(text.encode())
        self.process.stdin.flush()

    def wait_line(self, expected, timeout):
        deadline = time.monotonic() + timeout
        seen = []
        while time.monotonic() < deadline:
            if self.process.poll() is not None and self.lines.empty():
                raise RuntimeError(f"QEMU exited before {expected!r}: {self.process.returncode}")
            try:
                line = self.lines.get(timeout=min(0.2, max(0.001, deadline - time.monotonic())))
            except queue.Empty:
                continue
            seen.append(line)
            if line == expected:
                return seen
        raise TimeoutError(f"serial timeout waiting for exact line {expected!r}")

    def prove_ready(self, timeout):
        self.wait_line(READY, timeout)
        token = secrets.token_hex(12)
        marker = f"REDOX_BROWSER_DEMO_COMMAND:{token}:"
        self.send("printf '\\n'; browser_command " + token + " snix eval --expr '1 + 1'\n")
        output = self.wait_line(marker + "0", timeout)
        if "2" not in output:
            raise RuntimeError("Snix did not produce standalone result 2")
        return {"expression": "1 + 1", "expected": "2", "status": 0, "output": output}

    def connect_qmp(self, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            sock = socket.socket(socket.AF_UNIX)
            try:
                sock.connect(self.qmp_path)
                self.sock = sock
                sock.settimeout(timeout)
                self.qmp_file = sock.makefile("rb")
                greeting = json.loads(self.qmp_file.readline())
                if "QMP" not in greeting:
                    raise RuntimeError("invalid QMP greeting")
                self.qmp("qmp_capabilities")
                return
            except (FileNotFoundError, ConnectionRefusedError):
                sock.close()
                time.sleep(0.05)
        raise TimeoutError("QMP socket did not become ready")

    def qmp(self, command, **arguments):
        self.qmp_id += 1
        message = {"execute": command, "id": self.qmp_id}
        if arguments:
            message["arguments"] = arguments
        self.qmp_log.write(json.dumps({"send": message}) + "\n")
        self.qmp_log.flush()
        self.sock.sendall(json.dumps(message).encode() + b"\n")
        while True:
            line = self.qmp_file.readline()
            if not line:
                raise RuntimeError("QMP disconnected")
            reply = json.loads(line)
            self.qmp_log.write(json.dumps({"receive": reply}) + "\n")
            self.qmp_log.flush()
            if reply.get("id") == self.qmp_id:
                if "error" in reply:
                    raise RuntimeError(f"QMP {command}: {reply['error']}")
                return reply["return"]

    def close(self):
        if self.process.poll() is None:
            try:
                if self.sock:
                    self.qmp("quit")
                else:
                    self.process.terminate()
            except (OSError, RuntimeError):
                self.process.terminate()
        try:
            status = self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            status = self.process.wait()
        self.thread.join(timeout=5)
        self.serial.close()
        self.stderr.close()
        if self.qmp_file:
            self.qmp_file.close()
        if self.sock:
            self.sock.close()
        self.qmp_log.close()
        Path(self.qmp_path).unlink(missing_ok=True)
        return status


def parser(description):
    result = argparse.ArgumentParser(description=description)
    result.add_argument("--manifest", required=True)
    result.add_argument("--pack", required=True)
    result.add_argument("--disk", required=True)
    result.add_argument("--engine-dir", required=True)
    result.add_argument("--qemu", default=os.environ.get("REDOX_NATIVE_QEMU"), required=not os.environ.get("REDOX_NATIVE_QEMU"))
    result.add_argument("--native-provenance", default=os.environ.get("REDOX_NATIVE_PROVENANCE"), required=not os.environ.get("REDOX_NATIVE_PROVENANCE"))
    result.add_argument("--out", required=True)
    result.add_argument("--timeout", type=float, default=600)
    return result


def main():
    args = parser(__doc__).parse_args()
    manifest, native, provenance = configuration(args)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=False)
    shutil.copyfile(args.manifest, out / "runtime-manifest.json")
    evidence = {"schemaVersion": 1, "mode": "cold", "kind": "native", "success": False, "manifestHash": identity(args.manifest)["sha256"], "machineHash": manifest["machineHash"], "assets": manifest["assets"], "nativeEngine": native, "nativeProvenance": provenance, "readyMarker": READY}
    evidence["firmwareFiles"] = manifest.get("firmwareFiles", {})
    evidence["revision"] = manifest["revision"]
    evidence["sourceRevision"] = manifest["sourceRevision"]
    evidence["runtimeRevision"] = manifest["runtimeRevision"]
    evidence["machine"] = manifest["machine"]
    vm = None
    try:
        vm = VM(args, manifest, out)
        evidence["args"] = vm.command
        evidence["snix"] = vm.prove_ready(args.timeout)
        vm.connect_qmp(args.timeout)
        evidence["supportedMachines"] = vm.qmp("query-machines")
        evidence["resolvedCpu"] = vm.qmp("query-cpus-fast")
        evidence["success"] = True
    except Exception as error:
        evidence["error"] = str(error)
    finally:
        if vm:
            evidence["exitStatus"] = vm.close()
            if evidence["exitStatus"] != 0:
                evidence["success"] = False
                evidence["error"] = "native QEMU exited unsuccessfully"
            evidence["elapsedMs"] = (time.monotonic() - vm.started) * 1000
        evidence["logs"] = {path.name: identity(path) for path in out.iterdir() if path.suffix in (".log", ".jsonl")}
        save(out / "evidence.json", evidence)
    return 0 if evidence["success"] else 1


if __name__ == "__main__":
    sys.exit(main())
