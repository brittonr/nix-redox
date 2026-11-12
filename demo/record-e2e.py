#!/usr/bin/env python3
"""Record a reproducible nix-redox demo as an asciinema cast.

Boots a Redox image in QEMU, logs in over the serial console, runs
`tree --version`, `snix eval`, `snix system info`, and `snix system services`,
then renders the resulting cast to an MP4 with `agg`.

The guest is driven through a QEMU serial socket.  The serial console is the
source of truth: asciinema records exactly what the guest emits, including the
typed commands echoed by the shell.  No graphical session is required.

Requirements: qemu-system-x86_64 with KVM, OVMF.fd, a Redox UEFI bootloader,
asciinema, asciinema-agg, and ffmpeg.  On Nix:

  nix shell nixpkgs#asciinema nixpkgs#asciinema-agg -c \
    python3 demo/record-e2e.py --image ... --bootloader ... --ovmf ... \
    --output docs/assets/demo/nix-redox-e2e.mp4
"""

import argparse
import os
import shlex
import shutil
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

COMMANDS = [
    ("tree --version", 1.0),
    ('snix eval --expr "1 + 1"', 1.2),
    (
        "snix build --expr 'derivation { name = \"nix-demo\"; "
        "builder = \"/nix/system/profile/bin/bash\"; "
        "args = [ \"-c\" \"echo built-with-nix > $out\" ]; "
        "system = \"x86_64-unknown-redox\"; }'",
        3.0,
    ),
    ("cat /nix/store/*-nix-demo", 1.5),
    ("snix system info", 2.8),
    ("snix system services", 3.2),
]

TYPE_DELAY = 0.035


class SerialCapture:
    """Read the QEMU serial socket, tee it to stdout, and retain a tail."""

    def __init__(self, sock: socket.socket, limit: int = 4_000_000):
        self.sock = sock
        self.limit = limit
        self.buffer = bytearray()
        self.lock = threading.Lock()
        self.running = True
        self.thread = threading.Thread(target=self._read, daemon=True)

    def start(self) -> None:
        self.thread.start()

    def _read(self) -> None:
        while self.running:
            try:
                data = self.sock.recv(65536)
            except socket.timeout:
                continue
            except OSError:
                break
            if not data:
                break
            with self.lock:
                self.buffer.extend(data)
                if len(self.buffer) > self.limit:
                    del self.buffer[: len(self.buffer) - self.limit]
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()

    def contains(self, needle: bytes) -> bool:
        with self.lock:
            return needle in self.buffer

    def length(self) -> int:
        with self.lock:
            return len(self.buffer)

    def wait_prompt(self, after: int, timeout: float = 180.0) -> bool:
        """Wait until a fresh shell prompt is at the tail and has settled."""
        deadline = time.monotonic() + timeout
        last_length = after
        stable_since = None
        while time.monotonic() < deadline:
            with self.lock:
                length = len(self.buffer)
                tail = bytes(self.buffer[-80:])
            if length <= after or b"redox# " not in tail:
                stable_since = None
                last_length = length
                time.sleep(0.05)
                continue
            if length == last_length:
                if stable_since is None:
                    stable_since = time.monotonic()
                elif time.monotonic() - stable_since > 0.35:
                    return True
            else:
                stable_since = time.monotonic()
                last_length = length
            time.sleep(0.05)
        return False

    def wait(self, needle: bytes, timeout: float) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.contains(needle):
                return True
            time.sleep(0.05)
        return False

    def close(self) -> None:
        self.running = False
        try:
            self.thread.join(timeout=2)
        except RuntimeError:
            pass


def wait_for_path(path: Path, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.05)
    raise TimeoutError(f"timed out waiting for {path}")


def guest_session(args: argparse.Namespace) -> int:
    """Run QEMU and drive the guest; stdout is the serial stream for asciinema."""

    work = Path(args.work)
    work.mkdir(parents=True, exist_ok=True)
    serial_path = work / "serial.sock"
    monitor_path = work / "monitor.sock"
    qemu_log = open(work / "qemu.log", "wb")
    for path in (serial_path, monitor_path):
        try:
            path.unlink()
        except FileNotFoundError:
            pass

    env = os.environ.copy()
    env.pop("LD_LIBRARY_PATH", None)
    env.pop("LD_PRELOAD", None)
    qemu = [
        args.qemu,
        "-M", "pc",
        "-cpu", "host",
        "-m", "2048",
        "-smp", "4",
        "-enable-kvm",
        "-snapshot",
        "-kernel", args.bootloader,
        "-bios", args.ovmf,
        "-drive", f"file={os.path.realpath(args.image)},format=raw,if=none,id=disk0",
        "-device", "virtio-blk-pci,drive=disk0",
        "-vga", "std",
        "-display", "none",
        "-monitor", f"unix:{monitor_path},server=on,wait=off",
        "-serial", f"unix:{serial_path},server=on,wait=off",
    ]
    process = subprocess.Popen(
        qemu,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=qemu_log,
        start_new_session=True,
    )
    capture = None
    try:
        wait_for_path(serial_path, 20)
        sock = socket.socket(socket.AF_UNIX)
        sock.settimeout(0.2)
        sock.connect(str(serial_path))
        capture = SerialCapture(sock)
        capture.start()

        # UEFI has loaded the Redox bootloader by now.  A carriage return
        # selects the default boot entry; LF is not an Enter key on this path.
        if capture.wait(b"Press e to edit", 20):
            time.sleep(0.6)
            sock.sendall(b"\r")
        else:
            time.sleep(8)
            sock.sendall(b"\r")

        if not capture.wait(b"Redox OS starting", 30) and not capture.wait(b"login:", 5):
            # A second Enter recovers from the bootloader's environment editor.
            sock.sendall(b"\r")
            if not capture.wait(b"Redox OS starting", 20) and not capture.wait(b"login:", 15):
                print("guest did not reach the kernel or login prompt", file=sys.stderr)
                return 1

        if not capture.wait(b"login:", 45):
            print("guest did not reach the login prompt", file=sys.stderr)
            return 1
        time.sleep(0.4)
        sock.sendall(b"root\r")
        if not capture.wait(b"password:", 15):
            print("guest did not reach the password prompt", file=sys.stderr)
            return 1
        time.sleep(0.3)
        sock.sendall(b"redox\r")
        if not capture.wait(b"redox#", 20):
            print("guest login failed", file=sys.stderr)
            return 1
        time.sleep(1.0)

        for command, delay in COMMANDS:
            start = capture.length()
            for char in command:
                sock.sendall(char.encode())
                time.sleep(TYPE_DELAY)
            sock.sendall(b"\r")
            if not capture.wait_prompt(start, timeout=180):
                print(f"guest did not finish command: {command}", file=sys.stderr)
                return 1
            time.sleep(delay)
        time.sleep(1.5)
        return 0
    finally:
        if capture is not None:
            capture.close()
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
        qemu_log.close()


def resolve_tool(explicit: str | None, name: str, hint: str) -> str:
    if explicit:
        return explicit
    found = shutil.which(name)
    if found:
        return found
    raise SystemExit(f"{name} not found; {hint}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", required=True, help="Redox redox.img")
    parser.add_argument("--bootloader", required=True, help="BOOTX64.EFI")
    parser.add_argument("--ovmf", required=True, help="OVMF.fd")
    parser.add_argument("--qemu", default="qemu-system-x86_64")
    parser.add_argument("--asciinema", default=None)
    parser.add_argument("--agg", default=None)
    parser.add_argument("--output", default="nix-redox-e2e.mp4")
    parser.add_argument("--cast", default=None, help="asciicast output path")
    parser.add_argument("--theme", default="github-dark")
    parser.add_argument("--font-size", type=int, default=14)
    parser.add_argument("--keep-work", action="store_true")
    parser.add_argument("--guest-mode", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--work", default="/var/tmp/redox-asciinema", help=argparse.SUPPRESS)
    args = parser.parse_args()

    if args.guest_mode:
        return guest_session(args)

    asciinema = resolve_tool(
        args.asciinema,
        "asciinema",
        "run inside `nix shell nixpkgs#asciinema`",
    )
    agg = resolve_tool(
        args.agg,
        "agg",
        "run inside `nix shell nixpkgs#asciinema-agg`",
    )

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    cast = Path(args.cast) if args.cast else output.with_suffix(".cast")
    work = Path(args.work)
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)

    guest_args = [
        sys.executable,
        str(Path(__file__).resolve()),
        "--guest-mode",
        "--image", args.image,
        "--bootloader", args.bootloader,
        "--ovmf", args.ovmf,
        "--qemu", args.qemu,
        "--work", str(work),
    ]
    command = shlex.join(guest_args)
    rec = [
        asciinema,
        "rec",
        "--headless",
        "--quiet",
        "--overwrite",
        "--return",
        "--output-format", "asciicast-v2",
        "--window-size", "120x40",
        "--idle-time-limit", "2",
        "--title", "nix-redox: a Nix-built Redox OS",
        "--command", command,
        str(cast),
    ]
    subprocess.run(rec, check=True)

    if not cast.exists() or cast.stat().st_size < 1000:
        print(f"asciinema did not produce a usable cast at {cast}", file=sys.stderr)
        return 1

    gif = work / "terminal.gif"
    subprocess.run(
        [
            agg,
            "--quiet",
            "--theme", args.theme,
            "--font-size", str(args.font_size),
            "--line-height", "1.28",
            "--cols", "120",
            "--rows", "40",
            "--fps-cap", "6",
            "--last-frame-duration", "2",
            "--idle-time-limit", "2",
            str(cast),
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
            "-vf", "fps=6,scale=900:-2",
            "-c:v", "libx264",
            "-preset", "slow",
            "-crf", "38",
            "-pix_fmt", "yuv420p",
            "-movflags", "+faststart",
            str(output),
        ],
        check=True,
    )

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
    poster = output.with_name(output.stem + "-poster.png")
    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-loglevel", "error",
            "-ss", f"{duration * 0.75:.2f}",
            "-i", str(output),
            "-frames:v", "1",
            str(poster),
        ],
        check=True,
    )

    print(f"wrote {cast} ({cast.stat().st_size} bytes)")
    print(f"wrote {output} ({output.stat().st_size} bytes)")
    print(f"wrote {poster} ({poster.stat().st_size} bytes)")
    if not args.keep_work:
        shutil.rmtree(work)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
