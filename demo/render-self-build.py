#!/usr/bin/env python3
"""Render a self-building Redox evidence video from a native proof capture.

The source of truth is a completed `native-rebuild-test` capture directory.
This script selects the boot/build/verification milestones from the three
serial logs, emits a timed asciicast, and renders it with `agg` and ffmpeg.

This is an evidence replay, not a live run: the terminal output is copied from
the capture and the timeline is compressed for viewing.
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def clean(line: str) -> str:
    return ANSI.sub("", line.replace("\r", "")).rstrip()


def read_lines(path: Path) -> list[str]:
    if not path.exists():
        raise SystemExit(f"missing capture log: {path}")
    return [clean(line) for line in path.read_text(errors="replace").splitlines()]


def matching(lines: list[str], needles: list[str]) -> list[str]:
    return [line for line in lines if any(needle in line for needle in needles)]


def sampled(lines: list[str], needle: str, step: int = 7) -> list[str]:
    found = [line for line in lines if needle in line]
    return found[::step]


class Cast:
    def __init__(self) -> None:
        self.events: list[list] = []
        self.t = 0.0

    def out(self, text: str, delay: float = 0.0) -> None:
        self.events.append([round(self.t, 4), "o", text])
        self.t += delay

    def line(self, text: str = "", delay: float = 0.14) -> None:
        self.out(text + "\r\n", delay)

    def clear(self) -> None:
        self.out("\x1b[2J\x1b[H", 0.1)

    def pause(self, seconds: float) -> None:
        self.t += seconds


def add_phase(cast: Cast, title: str, subtitle: str) -> None:
    cast.clear()
    cast.line("=" * 72, 0.02)
    cast.line(title, 0.02)
    cast.line(subtitle, 0.02)
    cast.line("=" * 72, 0.2)


def render(args: argparse.Namespace) -> int:
    capture = Path(args.capture)
    summary = json.loads((capture / "summary.json").read_text())
    if summary.get("flow") != "native-rebuild-test":
        raise SystemExit("capture is not a native-rebuild-test run")
    if summary.get("verdict") != "pass":
        raise SystemExit("capture verdict is not pass")

    seed = read_lines(capture / "boot-0-seed.serial.log")
    native = read_lines(capture / "boot-1-native.serial.log")
    rollback = read_lines(capture / "boot-2-rollback.serial.log")
    counts = summary["test_counts"]
    cycles = summary["boot_cycles"]

    cast = Cast()
    cast.clear()
    cast.line("REDOX BUILDS REDOX", 0.15)
    cast.line("native self-hosting proof", 0.15)
    cast.line("", 0.1)
    cast.line(f"run     {summary['run_id']}", 0.12)
    cast.line(f"commit  {summary['git_rev']}", 0.12)
    cast.line(f"result  {counts['pass']}/{counts['total']} pass · 0 fail · 0 skip", 0.12)
    cast.line("boots   seed -> native -> rollback", 0.12)
    cast.line(f"time    {summary['duration_seconds']} s, compressed for this video", 0.12)
    cast.line("", 0.1)
    cast.line("evidence replay; original entrypoint:", 0.12)
    cast.line("$ nix run .#native-rebuild-test", 0.12)
    cast.line("", 0.1)
    cast.line("Selected guest serial output follows.", 0.8)

    add_phase(
        cast,
        "PHASE 1/3  SEED BOOT",
        "build the native kernel, bootloader, initfs and system inside Redox",
    )
    for line in matching(
        seed,
        [
            "BOOT_PROOF:bootloader:",
            "Redox OS Bootloader",
            "BOOT_PROOF:kernel:",
            "BOOT_PROOF:initfs:",
            "Native proof boot phase: seed",
            "FUNC_TEST:durable-flush-helper-built:PASS",
            "FUNC_TEST:native-inputs:PASS",
            "FUNC_TEST:no-build-bridge:PASS",
            "FUNC_TEST:original-manifest:PASS",
        ],
    ):
        cast.line(line, 0.2)
    cast.pause(1.2)

    # Show the long native build as compressed elapsed heartbeats, then the
    # post-build assertions in their actual order.
    add_phase(
        cast,
        "PHASE 1/3  NATIVE BUILD",
        "snix rebuilds the system graph without a Linux build bridge",
    )
    for line in sampled(seed, "[native-system:rebuild] elapsed=", step=8):
        cast.line(line, 0.22)
    cast.pause(0.8)
    cast.line("native system build: complete", 0.5)
    for line in matching(
        seed,
        [
            "FUNC_TEST:native-system-rebuild:PASS",
            "FUNC_TEST:native-output-is-store:PASS",
            "FUNC_TEST:graph-not-prebuilt:PASS",
            "FUNC_TEST:native-output-identity:PASS",
            "FUNC_ARTIFACT:native-toplevel:",
            "FUNC_TEST:generation-advanced:PASS",
            "FUNC_TEST:kernel-elf-machine:PASS",
            "FUNC_TEST:bootloader-pe-machine:PASS",
            "FUNC_TEST:native-kernel-not-seed:PASS",
            "FUNC_TEST:native-initfs-not-seed:PASS",
            "FUNC_TEST:native-bootloader-not-seed:PASS",
            "FUNC_TEST:native-initfs-consumer:PASS",
            "FUNC_TEST:native-build-failure:PASS",
            "FUNC_TEST:failure-manifest-unchanged:PASS",
            "FUNC_TEST:boot-default-consumer:PASS",
            "FUNC_EXPECT:",
            "FUNC_TEST:native-restart-efi:PASS",
            "FUNC_REBOOT:native:",
        ],
    ):
        cast.line(line, 0.2)
    cast.pause(1.2)

    add_phase(
        cast,
        "PHASE 2/3  NATIVE BOOT",
        "firmware boots the guest-built bootloader, kernel and initfs",
    )
    for line in matching(
        native,
        [
            "BOOT_PROOF:bootloader:",
            "BOOT_PROOF:kernel:",
            "BOOT_PROOF:initfs:",
            "Native proof boot phase: native",
            "FUNC_TEST:native-boot-generation:PASS",
            "FUNC_TEST:boot-selected-native-identity:PASS",
            "FUNC_TEST:boot-selected-kernel:PASS",
            "FUNC_TEST:boot-selected-initfs:PASS",
            "FUNC_TEST:native-boot-etc:PASS",
            "FUNC_TEST:native-boot-removed-service:PASS",
            "FUNC_TEST:native-boot-retained-service:PASS",
            "FUNC_TEST:native-system-rollback:PASS",
            "Switching from generation",
            "Switched to generation",
            "FUNC_TEST:rollback-boot-previous:PASS",
            "FUNC_REBOOT:rollback:",
        ],
    ):
        cast.line(line, 0.22)
    cast.pause(1.2)

    add_phase(
        cast,
        "PHASE 3/3  ROLLBACK BOOT",
        "the original system is selected and verified byte-for-byte",
    )
    for line in matching(
        rollback,
        [
            "BOOT_PROOF:bootloader:",
            "BOOT_PROOF:kernel:",
            "BOOT_PROOF:initfs:",
            "Native proof boot phase: rollback",
            "FUNC_TEST:rollback-running-generation:PASS",
            "FUNC_TEST:rollback-kernel-bytes:PASS",
            "FUNC_TEST:rollback-initfs-bytes:PASS",
            "FUNC_TEST:rollback-system-identity:PASS",
            "FUNC_TEST:saved-native-still-rooted:PASS",
            "FUNC_TEST:no-build-bridge-after-rebuild:PASS",
            "FUNC_TESTS_COMPLETE",
        ],
    ):
        cast.line(line, 0.24)
    cast.pause(1.0)

    cast.clear()
    cast.line("REDOX BUILDS REDOX", 0.15)
    cast.line("", 0.1)
    cast.line(f"{counts['pass']} passed · {counts['fail']} failed · {counts['skip']} skipped", 0.2)
    cast.line(f"{len(cycles)} cold firmware boots on one writable disk", 0.2)
    cast.line("", 0.1)
    native_toplevel = summary.get("artifacts", {}).get("native-toplevel")
    if native_toplevel:
        cast.line(f"native top  {native_toplevel}", 0.16)
    for cycle in cycles:
        ids = cycle.get("identities", {})
        phase = cycle.get("phase", "?")
        bootloader = (ids.get("bootloader") or ["?"])[0].rsplit("/", 1)[-1]
        kernel = (ids.get("kernel") or ["?"])[0].rsplit("/", 1)[-1]
        initfs = (ids.get("initfs") or ["?"])[0].rsplit("/", 1)[-1]
        cast.line(f"{phase:8} {bootloader}", 0.16)
        cast.line(f"{'':8} {kernel}", 0.16)
        cast.line(f"{'':8} {initfs}", 0.16)
    cast.line("", 0.1)
    cast.line("The native generation remains GC-rooted.", 0.15)
    cast.line("Evidence: docs/self-hosting/latest-success.md", 0.2)
    cast.pause(2.5)

    cast_path = Path(args.cast)
    cast_path.parent.mkdir(parents=True, exist_ok=True)
    header = {
        "version": 2,
        "width": 120,
        "height": 40,
        "timestamp": 0,
        "idle_time_limit": 2,
        "title": "Redox builds Redox - native rebuild proof",
    }
    with cast_path.open("w") as handle:
        handle.write(json.dumps(header) + "\n")
        for event in cast.events:
            handle.write(json.dumps(event) + "\n")

    agg = args.agg or shutil.which("agg")
    if not agg:
        raise SystemExit("agg not found; run inside `nix shell nixpkgs#asciinema-agg`")

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    gif = cast_path.with_suffix(".gif")
    subprocess.run(
        [
            agg,
            "--quiet",
            "--theme", args.theme,
            "--font-size", str(args.font_size),
            "--line-height", "1.28",
            "--cols", "120",
            "--rows", "40",
            "--fps-cap", str(args.fps),
            "--last-frame-duration", "3",
            "--idle-time-limit", "2",
            str(cast_path),
            str(gif),
        ],
        check=True,
    )
    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-loglevel", "error",
            "-i", str(gif),
            "-vf", f"fps={args.fps},scale={args.width}:-2",
            "-c:v", "libx264",
            "-preset", "slow",
            "-crf", str(args.crf),
            "-pix_fmt", "yuv420p",
            "-movflags", "+faststart",
            str(output),
        ],
        check=True,
    )
    poster = output.with_name(output.stem + "-poster.png")
    duration = float(
        subprocess.check_output(
            [
                "ffprobe",
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=nw=1:nk=1",
                str(output),
            ],
            text=True,
        ).strip()
    )
    # The finished summary screen is held through the cast's final pause and
    # agg's --last-frame-duration, so one second before the end is always on it.
    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-loglevel", "error",
            "-sseof", "-1",
            "-i", str(output),
            "-frames:v", "1",
            str(poster),
        ],
        check=True,
    )
    if not args.keep_gif:
        gif.unlink(missing_ok=True)
    print(f"wrote {cast_path} ({cast_path.stat().st_size} bytes)")
    print(f"wrote {output} ({output.stat().st_size} bytes, {duration:.1f}s)")
    print(f"wrote {poster} ({poster.stat().st_size} bytes)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--capture", required=True, help="native-rebuild-test capture directory")
    parser.add_argument("--output", default="nix-redox-self-build.mp4")
    parser.add_argument("--cast", default=None)
    parser.add_argument("--agg", default=None)
    parser.add_argument("--theme", default="github-dark")
    parser.add_argument("--font-size", type=int, default=14)
    parser.add_argument("--fps", type=int, default=5)
    parser.add_argument("--width", type=int, default=900)
    parser.add_argument("--crf", type=int, default=38)
    parser.add_argument("--keep-gif", action="store_true")
    args = parser.parse_args()
    if args.cast is None:
        args.cast = str(Path(args.output).with_suffix(".cast"))
    return render(args)


if __name__ == "__main__":
    raise SystemExit(main())
