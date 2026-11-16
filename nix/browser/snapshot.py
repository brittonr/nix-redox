#!/usr/bin/env python3
"""Capture a native-to-browser bundle only after matched native/browser cold proof.

The guest sync helper and tokenized capture.sh reader establish readiness. QEMU
then pauses at migration pre-switchover, completes device serialization and
bdrv_inactivate_all (which drains/flushes disks), and stays postmigrate while the
raw disk is copied. The stream records the original running state, not a manual
QMP stop. No cont is sent on the source after this boundary.
"""
import hashlib
from pathlib import Path
import secrets
import shutil
import sys
import time

from launch import READY, VM, canonical, check_file, configuration, identity, load, parser, save


def require_proof(path, kind, manifest, native):
    proof = load(path)
    if proof.get("schemaVersion") != 1 or proof.get("kind") != kind or proof.get("mode") != "cold" or proof.get("success") is not True:
        raise ValueError(f"{kind} successful cold-boot evidence required")
    if proof.get("sourceRevision") != manifest["sourceRevision"] or proof.get("runtimeRevision") != manifest["runtimeRevision"] or proof.get("machineHash") != manifest["machineHash"] or proof.get("assets") != manifest["assets"]:
        raise ValueError(f"{kind} evidence artifact/machine mismatch")
    if proof.get("firmwareFiles", {}) != manifest.get("firmwareFiles", {}):
        raise ValueError(f"{kind} evidence firmware ROM mismatch")
    if proof.get("readyMarker") != READY or proof.get("snix", {}).get("status") != 0 or proof["snix"].get("expression") != "1 + 1" or proof["snix"].get("expected") != "2":
        raise ValueError(f"{kind} evidence lacks shell/Snix proof")
    if kind == "native" and proof.get("nativeEngine") != native:
        raise ValueError("native evidence executable mismatch")
    if kind == "browser" and not proof.get("browser"):
        raise ValueError("browser evidence lacks browser/version identity")
    return proof


def migration_status(vm, wanted, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = vm.qmp("query-migrate")
        status = result.get("status")
        if status in ("failed", "cancelled"):
            raise RuntimeError(f"migration {status}: {result}")
        if status == wanted:
            return result
        time.sleep(0.05)
    raise TimeoutError(f"migration did not reach {wanted}")


def safe_artifact_path(value):
    return isinstance(value, str) and all(
        segment not in ("", ".", "..") and all(character.isascii() and (character.isalnum() or character in "_,.-") for character in segment)
        for segment in value.split("/")
    )


def validate_bundle(bundle, manifest, native):
    root = Path(bundle)
    metadata = load(root / "snapshot.json")
    if metadata.get("schemaVersion") != 1 or metadata.get("kind") != "redox-browser-snapshot":
        raise ValueError("unsupported snapshot bundle")
    if metadata["machineHash"] != manifest["machineHash"] or metadata["machine"] != manifest["machine"]:
        raise ValueError("snapshot machine/CPU/RAM mismatch")
    if metadata["bindings"]["runtimeAssets"] != manifest["assets"] or metadata["bindings"]["nativeEngine"] != native:
        raise ValueError("snapshot engine/disk/firmware/EFI mismatch")
    if metadata["bindings"]["sourceRevision"] != manifest["sourceRevision"] or metadata["bindings"]["runtimeRevision"] != manifest["runtimeRevision"]:
        raise ValueError("snapshot source/runtime revision mismatch")
    if metadata["bindings"].get("firmwareFiles", {}) != manifest.get("firmwareFiles", {}):
        raise ValueError("snapshot firmware ROM mismatch")
    if metadata["firmwareState"] != manifest["machine"]["firmware"]:
        raise ValueError("snapshot firmware state mismatch")
    for role, artifact in metadata["artifacts"].items():
        if not safe_artifact_path(artifact.get("file")):
            raise ValueError(f"unsafe snapshot artifact path: {role}")
        relative = Path(artifact["file"])
        check_file(root / relative, artifact, role)
    for role in metadata["bindings"]["captureAssets"]:
        if metadata["bindings"]["captureAssets"][role] != metadata["artifacts"][role]:
            raise ValueError(f"snapshot {role} binding mismatch")
    for filename, expected in manifest.get("firmwareFiles", {}).items():
        check_file(root / metadata["artifacts"]["rom:" + filename]["file"], expected, f"snapshot firmware ROM {filename}")
    expected = hashlib.sha256(canonical(metadata["bindings"])).hexdigest()
    if metadata["compatibilityHash"] != expected:
        raise ValueError("snapshot compatibility binding mismatch")
    return metadata


def main():
    options = parser(__doc__)
    options.add_argument("--native-evidence")
    options.add_argument("--browser-evidence")
    options.add_argument("--efi", help="the manifest's exact EFI executable")
    options.add_argument("--validate", action="store_true", help="validate existing --out without launching")
    args = options.parse_args()
    manifest, native, provenance = configuration(args)
    if args.validate:
        validate_bundle(args.out, manifest, native)
        return 0
    if not args.native_evidence or not args.browser_evidence or not args.efi:
        options.error("capture requires --native-evidence, --browser-evidence, and --efi")
    require_proof(args.native_evidence, "native", manifest, native)
    require_proof(args.browser_evidence, "browser", manifest, native)
    check_file(args.efi, manifest["assets"]["efi"], "EFI")
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=False)
    token = secrets.token_hex(16)
    ready = f"REDOX_BROWSER_CAPTURE_READY:v1:{token}"
    resume = f"REDOX_BROWSER_RESUME:v1:{token}"
    resumed = f"REDOX_BROWSER_RESUMED:v1:{token}"
    vm = None
    record = {"schemaVersion": 1, "kind": "capture-attempt", "success": False}
    try:
        vm = VM(args, manifest, out)
        record["snix"] = vm.prove_ready(args.timeout)
        # Match prove_ready(): the debug console does not echo a line break.
        command = f"printf '\\n'; /nix/system/profile/bin/bash /etc/browser-demo/capture.sh {token}\n"
        record["guestCaptureCommand"] = command
        vm.send(command)
        vm.wait_line(ready, args.timeout)
        record["guestCaptureReady"] = ready
        vm.connect_qmp(args.timeout)
        blocks = vm.qmp("query-block")
        for block in blocks:
            if block.get("inserted", {}).get("cache", {}).get("no-flush"):
                raise ValueError("capture refuses no-flush disk cache")
        record["blockState"] = blocks
        vm.qmp("migrate-set-capabilities", capabilities=[{"capability": "pause-before-switchover", "state": True}])
        vm.qmp("migrate", uri="file:" + str((out / "vm.state").resolve()))
        record["preSwitchover"] = migration_status(vm, "pre-switchover", args.timeout)
        paused = vm.qmp("query-status")
        if paused.get("running") is not False:
            raise RuntimeError("migration boundary did not pause guest CPUs")
        record["pausedStatus"] = paused
        vm.qmp("migrate-continue", state="pre-switchover")
        record["migration"] = migration_status(vm, "completed", args.timeout)
        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline:
            final = vm.qmp("query-status")
            if final.get("running") is False and final.get("status") == "postmigrate":
                break
            time.sleep(0.05)
        else:
            raise TimeoutError("source did not become inactive postmigrate")
        record["postMigrationStatus"] = final
        # Successful completion includes block graph drain/flush/inactivation in
        # this pinned QEMU's migration/savevm.c. fsync also persists host caches.
        with (out / "running.raw").open("r+b") as source:
            import os
            os.fsync(source.fileno())
        shutil.copyfile(out / "running.raw", out / "disk.raw")
        captured_disk = identity(out / "disk.raw")
        if captured_disk != identity(out / "running.raw"):
            raise RuntimeError("disk changed across paused migration boundary")
        firmware = manifest["machine"]["firmware"]
        shutil.copyfile(Path(args.pack) / firmware["file"], out / "OVMF.fd")
        shutil.copyfile(args.efi, out / "BOOTX64.EFI")
        shutil.copyfile(args.native_evidence, out / "native-cold.json")
        shutil.copyfile(args.browser_evidence, out / "browser-cold.json")
        shutil.copyfile(args.manifest, out / "runtime-manifest.json")
        rom_artifacts = {}
        for filename, artifact in manifest.get("firmwareFiles", {}).items():
            destination = out / "firmware-pack" / filename
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(Path(args.pack) / filename, destination)
            check_file(destination, artifact, f"captured firmware ROM {filename}")
            rom_artifacts["rom:" + filename] = {"file": str(destination.relative_to(out)), **identity(destination)}
        record["exitStatus"] = vm.close()
        record["elapsedMs"] = (time.monotonic() - vm.started) * 1000
        vm = None
        if record["exitStatus"] != 0:
            raise RuntimeError("native capture QEMU exited unsuccessfully")
        (out / "running.raw").unlink()
        artifacts = {role: {"file": filename, **identity(out / filename)} for role, filename in {"state": "vm.state", "disk": "disk.raw", "firmware": "OVMF.fd", "efi": "BOOTX64.EFI", "nativeEvidence": "native-cold.json", "browserEvidence": "browser-cold.json", "runtimeManifest": "runtime-manifest.json", "serial": "serial.log", "qmp": "qmp.jsonl", "stderr": "qemu.stderr.log", "args": "args.json"}.items()}
        artifacts.update(rom_artifacts)
        bindings = {"sourceRevision": manifest["sourceRevision"], "runtimeRevision": manifest["runtimeRevision"], "machineHash": manifest["machineHash"], "runtimeAssets": manifest["assets"], "firmwareFiles": manifest.get("firmwareFiles", {}), "nativeEngine": native, "captureAssets": {role: artifact for role, artifact in artifacts.items() if role in ("state", "disk", "firmware", "efi") or role.startswith("rom:")}}
        metadata = {"schemaVersion": 1, "kind": "redox-browser-snapshot", "sourceRevision": manifest["sourceRevision"], "machine": manifest["machine"], "machineHash": manifest["machineHash"], "firmwareState": firmware, "bindings": bindings, "compatibilityHash": hashlib.sha256(canonical(bindings)).hexdigest(), "artifacts": artifacts, "handshake": {"captureReady": ready, "resumeInput": resume + "\n", "resumedMarker": resumed, "timeoutMs": int(args.timeout * 1000)}, "restore": {"incoming": "file:{state}", "runState": "running", "diskPolicy": "private-copy-per-session", "network": "disabled", "entropy": "captured-not-fresh"}, "provenance": {"native": provenance, "recipe": "nix/browser/snapshot.py", "captureBoundary": "guest-flush; migration-pre-switchover; complete-drain-flush-inactivate; fsync; raw-disk-copy", "byteReproducible": False}}
        record["success"] = True
        metadata["capture"] = record
        save(out / "snapshot.json", metadata)
    except Exception as error:
        record["success"] = False
        record["error"] = str(error)
    finally:
        if vm:
            record["exitStatus"] = vm.close()
        save(out / "capture.json", record)
    return 0 if record["success"] else 1


if __name__ == "__main__":
    sys.exit(main())
