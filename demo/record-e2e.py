#!/usr/bin/env python3
"""Record a reproducible nix-redox end-to-end demo.

Boots a graphical Redox image in QEMU, logs in through Orbital, runs
`tree` and `snix system services`, captures the VGA surface through the QEMU
monitor, and encodes an MP4 with intro/outro cards.

Requirements: qemu-system-x86_64, OVMF.fd, a Redox UEFI bootloader EFI,
ffmpeg, ImageMagick, and a font. Input is sent through the QEMU HMP monitor;
no interactive desktop is required.
"""

import argparse
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

KEYMAP = {
    " ": "spc",
    "/": "slash",
    "-": "minus",
    ".": "dot",
    "_": "shift-minus",
}


class Hmp:
    def __init__(self, path: Path):
        self.path = path
        self.lock = threading.Lock()

    def send(self, command: str, settle: float = 0.18) -> None:
        with self.lock:
            sock = socket.socket(socket.AF_UNIX)
            sock.settimeout(5)
            sock.connect(str(self.path))
            time.sleep(0.12)
            try:
                sock.recv(4096)
            except OSError:
                pass
            sock.sendall((command + "\n").encode())
            time.sleep(settle)
            try:
                sock.recv(8192)
            except OSError:
                pass
            sock.close()


def wait_for(path: Path, timeout: float) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if path.exists():
            return
        time.sleep(0.1)
    raise TimeoutError(f"timed out waiting for {path}")


def wait_serial(path: Path, needle: str, timeout: float) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if path.exists() and needle in path.read_text(errors="replace"):
            return
        time.sleep(0.5)
    raise TimeoutError(f"timed out waiting for {needle!r} in {path}")


def type_text(hmp: Hmp, text: str, per_key: float = 0.075) -> None:
    for ch in text:
        hmp.send("sendkey " + KEYMAP.get(ch, ch), per_key)


def screenshot(hmp: Hmp, path: Path) -> None:
    hmp.send(f"screendump {path}", 0.25)


def card(path: Path, *, title: str, subtitle: str, footer: str, mono: bool, font: str, title_size: int = 84) -> None:
    family = "DejaVuSansMono" if mono else "DejaVuSans"
    subprocess.run(
        [
            "convert",
            "-size",
            "1280x800",
            "xc:#071c2c",
            "-font",
            font,
            "-fill",
            "#eef7ff",
            "-pointsize",
            str(title_size if not mono else 70),
            "-gravity",
            "center",
            "-annotate",
            "+0-90",
            title,
            "-font",
            font,
            "-pointsize",
            "30",
            "-fill",
            "#a9c4d8",
            "-annotate",
            "+0+10",
            subtitle,
            "-pointsize",
            "23",
            "-fill",
            "#63b3ed",
            "-annotate",
            "+0+82",
            footer,
            str(path),
        ],
        check=True,
    )


def encode_clip(image: Path, out: Path, seconds: float) -> None:
    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-loglevel",
            "error",
            "-loop",
            "1",
            "-t",
            str(seconds),
            "-i",
            str(image),
            "-vf",
            "fps=30,format=yuv420p",
            "-c:v",
            "libx264",
            "-preset",
            "medium",
            "-crf",
            "18",
            str(out),
        ],
        check=True,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", required=True, help="Redox graphical redox.img")
    parser.add_argument("--bootloader", required=True, help="BOOTX64.EFI")
    parser.add_argument("--ovmf", required=True, help="OVMF.fd")
    parser.add_argument("--qemu", default="qemu-system-x86_64")
    parser.add_argument("--output", default="nix-redox-e2e.mp4")
    parser.add_argument("--font", default=None)
    parser.add_argument("--keep-frames", action="store_true")
    args = parser.parse_args()

    font = args.font
    if font is None:
        font = subprocess.check_output(
            ["fc-match", "-f", "%{file}", "sans"], text=True
        ).strip()

    work = Path("/var/tmp/redox-demo-recording")
    if work.exists():
        shutil.rmtree(work)
    frames = work / "frames"
    frames.mkdir(parents=True)
    serial = work / "serial.log"
    monitor = work / "monitor.sock"
    for p in (serial, monitor):
        try:
            p.unlink()
        except FileNotFoundError:
            pass

    env = os.environ.copy()
    env.pop("LD_LIBRARY_PATH", None)
    env.pop("LD_PRELOAD", None)
    qemu = [
        args.qemu,
        "-M",
        "pc",
        "-cpu",
        "host",
        "-m",
        "2048",
        "-smp",
        "4",
        "-enable-kvm",
        "-snapshot",
        "-kernel",
        args.bootloader,
        "-bios",
        args.ovmf,
        "-drive",
        f"file={os.path.realpath(args.image)},format=raw,if=none,id=disk0",
        "-device",
        "virtio-blk-pci,drive=disk0",
        "-vga",
        "std",
        "-display",
        "none",
        "-monitor",
        f"unix:{monitor},server,nowait",
        "-serial",
        f"file:{serial}",
    ]
    process = subprocess.Popen(qemu, env=env, start_new_session=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    hmp = Hmp(monitor)
    recording = threading.Event()
    recorded: list[tuple[Path, float]] = []

    def grab() -> None:
        index = 0
        while recording.is_set():
            frame = frames / f"frame{index:05d}.ppm"
            try:
                hmp.send(f"screendump {frame}", 0.12)
            except OSError:
                break
            if frame.exists() and frame.stat().st_size > 0:
                recorded.append((frame, time.time()))
                index += 1
            time.sleep(0.08)

    try:
        wait_for(monitor, 20)
        time.sleep(3)
        hmp.send("sendkey ret")
        time.sleep(1)
        recording.set()
        grabber = threading.Thread(target=grab, daemon=True)
        grabber.start()

        wait_serial(serial, "GraphicScreen", 40)
        time.sleep(9)  # reach the Orbital login screen

        hmp.send("mouse_move 640 425")
        hmp.send("mouse_button 1")
        time.sleep(0.2)
        hmp.send("mouse_button 0")
        time.sleep(0.3)
        type_text(hmp, "redox", 0.12)
        hmp.send("sendkey ret", 0.4)
        time.sleep(8)  # orblogin starts orbterm

        type_text(hmp, "tree --version")
        hmp.send("sendkey ret", 0.4)
        time.sleep(1.3)
        type_text(hmp, "snix system info")
        hmp.send("sendkey ret", 0.4)
        time.sleep(2.2)
        type_text(hmp, "snix system services")
        hmp.send("sendkey ret", 0.4)
        time.sleep(3.0)
        time.sleep(2.0)
    finally:
        recording.clear()
        time.sleep(0.4)
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
        try:
            grabber.join(timeout=2)
        except NameError:
            pass

    if len(recorded) < 10:
        print("recording failed: too few frames", file=sys.stderr)
        return 1

    screen_list = work / "screen.ffconcat"
    with screen_list.open("w") as handle:
        handle.write("ffconcat version 1.0\n")
        for index, (frame, stamp) in enumerate(recorded):
            nxt = recorded[index + 1][1] if index + 1 < len(recorded) else stamp + 1.0
            duration = max(0.05, min(1.0, nxt - stamp))
            handle.write(f"file '{frame}'\n")
            handle.write(f"duration {duration:.4f}\n")

    screen = work / "screen.mp4"
    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-loglevel",
            "error",
            "-f",
            "concat",
            "-safe",
            "0",
            "-i",
            str(screen_list),
            "-vf",
            "fps=30,format=yuv420p",
            "-c:v",
            "libx264",
            "-preset",
            "medium",
            "-crf",
            "18",
            str(screen),
        ],
        check=True,
    )

    intro = work / "intro.png"
    outro = work / "outro.png"
    card(
        intro,
        title="nix-redox",
        subtitle="Redox OS, built with Nix",
        footer="A public alpha · MIT",
        mono=False,
        font=font,
    )
    card(
        outro,
        title="One command. A complete Redox OS.",
        subtitle="nix run github:brittonr/nix-redox",
        footer="brittonr.github.io/nix-redox · v0.1.2-alpha",
        mono=False,
        font=font,
        title_size=54,
    )
    intro_mp4 = work / "intro.mp4"
    outro_mp4 = work / "outro.mp4"
    encode_clip(intro, intro_mp4, 2.5)
    encode_clip(outro, outro_mp4, 3.5)

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-loglevel",
            "error",
            "-i",
            str(intro_mp4),
            "-i",
            str(screen),
            "-i",
            str(outro_mp4),
            "-filter_complex",
            "[0:v][1:v][2:v]concat=n=3:v=1:a=0[v]",
            "-map",
            "[v]",
            "-c:v",
            "libx264",
            "-preset",
            "slow",
            "-crf",
            "27",
            "-pix_fmt",
            "yuv420p",
            "-movflags",
            "+faststart",
            str(output),
        ],
        check=True,
    )
    print(f"wrote {output} ({output.stat().st_size} bytes, {len(recorded)} frames)")

    if not args.keep_frames:
        shutil.rmtree(work)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
