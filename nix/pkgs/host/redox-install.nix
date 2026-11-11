{ hostPkgs }:

hostPkgs.writeScriptBin "redox-install" ''
  #!${hostPkgs.python3}/bin/python3
  import argparse
  import hashlib
  import json
  import os
  import stat
  import subprocess
  import sys

  DD = "${hostPkgs.coreutils}/bin/dd"
  LSBLK = "${hostPkgs.util-linux}/bin/lsblk"
  CHUNK = 4 * 1024 * 1024


  def run(cmd, **kwargs):
      return subprocess.run(cmd, check=True, text=True, **kwargs)


  def image_hash(path):
      digest = hashlib.sha256()
      with open(path, "rb") as handle:
          while True:
              block = handle.read(CHUNK)
              if not block:
                  break
              digest.update(block)
      return digest.hexdigest()


  def expected_hash(path):
      checksum = path + ".sha256"
      if not os.path.isfile(checksum):
          return None
      text = open(checksum, encoding="utf-8").read().strip()
      if not text:
          return None
      return text.split()[0].lower()


  def device_info(path):
      try:
          result = run(
              [LSBLK, "-J", "-b", "-o", "NAME,SIZE,TYPE,MODEL,MOUNTPOINTS", path],
              capture_output=True,
          )
          data = json.loads(result.stdout)
          nodes = data.get("blockdevices", [])
          if not nodes:
              return None
          return nodes[0]
      except (subprocess.CalledProcessError, ValueError):
          return None


  def mounted(info):
      if not info:
          return False
      if info.get("mountpoints") and any(info["mountpoints"]):
          return True
      for child in info.get("children", []) or []:
          if child.get("mountpoints") and any(child["mountpoints"]):
              return True
          if mounted(child):
              return True
      return False


  def check_image(args):
      image = os.path.realpath(os.path.expanduser(args.image))
      if not os.path.isfile(image):
          print(f"redox-install: image not found: {image}", file=sys.stderr)
          return None, None
      actual = image_hash(image)
      expected = expected_hash(image)
      if expected and actual != expected:
          print("redox-install: image checksum mismatch", file=sys.stderr)
          print(f"  expected: {expected}", file=sys.stderr)
          print(f"  actual:   {actual}", file=sys.stderr)
          return None, None
      if expected:
          print(f"image checksum ok: {actual}")
      else:
          print(f"image checksum (no .sha256 sidecar): {actual}")
      return image, actual


  def device_checks(args, image):
      device = os.path.realpath(os.path.expanduser(args.device))
      if not os.path.exists(device):
          print(f"redox-install: device not found: {device}", file=sys.stderr)
          return None
      mode = os.stat(device).st_mode
      is_block = stat.S_ISBLK(mode)
      if not is_block and not args.force:
          print(
              f"redox-install: {device} is not a block device; use --force only for tests",
              file=sys.stderr,
          )
          return None
      if is_block and os.geteuid() != 0:
          print("redox-install: writing a block device requires root", file=sys.stderr)
          return None

      image_size = os.path.getsize(image)
      if is_block:
          info = device_info(device)
          if info is None:
              print(f"redox-install: cannot inspect block device {device}", file=sys.stderr)
              return None
          if mounted(info):
              print(f"redox-install: refusing mounted device {device}", file=sys.stderr)
              return None
          size = int(info.get("size", 0))
          if size < image_size:
              print(
                  f"redox-install: device is too small ({size} < {image_size} bytes)",
                  file=sys.stderr,
              )
              return None
          print(f"target: {device}  size={size}  model={info.get('model') or 'unknown'}")
      else:
          size = os.path.getsize(device)
          if size < image_size:
              print(
                  f"redox-install: target file is too small ({size} < {image_size} bytes)",
                  file=sys.stderr,
              )
              return None
          print(f"target file: {device}  size={size}")
      return device


  def confirm(args, device):
      if args.yes:
          return True
      print("")
      print(f"About to overwrite {device}.")
      print("This destroys the current contents of the target.")
      answer = input("Type WRITE to continue: ")
      return answer == "WRITE"


  def verify_write(device, image, image_digest):
      digest = hashlib.sha256()
      remaining = os.path.getsize(image)
      with open(device, "rb") as handle:
          while remaining > 0:
              block = handle.read(min(CHUNK, remaining))
              if not block:
                  break
              digest.update(block)
              remaining -= len(block)
      if remaining != 0:
          print("redox-install: target ended before the image was read back", file=sys.stderr)
          return False
      actual = digest.hexdigest()
      if actual != image_digest:
          print("redox-install: read-back verification failed", file=sys.stderr)
          print(f"  expected: {image_digest}", file=sys.stderr)
          print(f"  actual:   {actual}", file=sys.stderr)
          return False
      print(f"read-back verification ok: {actual}")
      return True


  def cmd_list(args):
      result = run(
          [LSBLK, "-J", "-b", "-o", "NAME,SIZE,TYPE,MODEL,TRAN,MOUNTPOINTS"],
          capture_output=True,
      )
      data = json.loads(result.stdout)

      def emit(node, depth=0):
          name = node.get("name", "?")
          size = int(node.get("size", 0) or 0)
          kind = node.get("type", "?")
          model = node.get("model") or ""
          mounts = node.get("mountpoints") or []
          mount_text = ",".join(m for m in mounts if m)
          indent = "  " * depth
          print(
              f"{indent}{name:12} {kind:8} {size / (1024**3):8.2f} GiB  "
              f"{model:24} {mount_text}"
          )
          for child in node.get("children", []) or []:
              emit(child, depth + 1)

      for node in data.get("blockdevices", []):
          emit(node)
      return 0


  def cmd_verify(args):
      image, _ = check_image(args)
      return 0 if image else 1


  def cmd_write(args):
      image, digest = check_image(args)
      if not image:
          return 1
      device = device_checks(args, image)
      if not device:
          return 1
      if args.dry_run:
          print(f"dry run: would write {image} ({os.path.getsize(image)} bytes) to {device}")
          return 0
      if not confirm(args, device):
          print("aborted", file=sys.stderr)
          return 1

      print(f"writing {image} to {device}...")
      run([DD, f"if={image}", f"of={device}", "bs=4M", "conv=fsync", "status=progress"])
      os.sync()
      print("write complete")
      if not args.no_verify and not verify_write(device, image, digest):
          return 1
      return 0


  def main():
      parser = argparse.ArgumentParser(
          prog="redox-install",
          description="Write a Redox disk image to a block device with validation.",
      )
      sub = parser.add_subparsers(dest="command", required=True)

      listing = sub.add_parser("list", help="list block devices")
      listing.set_defaults(func=cmd_list)

      verify = sub.add_parser("verify", help="verify an image and its .sha256 sidecar")
      verify.add_argument("--image", required=True)
      verify.set_defaults(func=cmd_verify)

      write = sub.add_parser("write", help="write an image to a device")
      write.add_argument("--image", required=True)
      write.add_argument("--device", required=True)
      write.add_argument("--yes", action="store_true", help="skip the WRITE confirmation")
      write.add_argument("--dry-run", action="store_true")
      write.add_argument("--no-verify", action="store_true", help="skip read-back verification")
      write.add_argument(
          "--force",
          action="store_true",
          help="allow a regular file target (testing only)",
      )
      write.set_defaults(func=cmd_write)

      args = parser.parse_args()
      return args.func(args)


  if __name__ == "__main__":
      sys.exit(main())
''
