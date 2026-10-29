#!/usr/bin/env python3
"""Instrument the pinned Redox sources with executing-artifact serial identities.

Both the seed factory and offline native source bundle use these exact patches.
The identity is supplied by the compiling derivation, never by the rootfs runner.
"""

import argparse
from pathlib import Path


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    if text.count(old) != 1:
        raise SystemExit(f"{path}: expected exactly one pinned boot entry anchor")
    path.write_text(text.replace(old, new, 1))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("component", choices=("kernel", "bootloader"))
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    if args.component == "kernel":
        replace_once(
            args.source / "src/arch/x86_shared/start.rs",
            '            info!("Redox OS starting...");\n',
            '            if let Some(identity) = option_env!("REDOX_BOOT_PROOF_ID") {\n'
            '                println!("BOOT_PROOF:kernel:{}", identity);\n'
            '            }\n'
            '            info!("Redox OS starting...");\n',
        )
    else:
        replace_once(
            args.source / "src/main.rs",
            'fn main(os: &impl Os) -> (usize, u64, KernelArgs) {\n',
            'fn main(os: &impl Os) -> (usize, u64, KernelArgs) {\n'
            '    #[cfg(target_arch = "x86_64")]\n'
            '    if let Some(identity) = option_env!("REDOX_BOOT_PROOF_ID") {\n'
            '        // Write COM1 directly: firmware ConsoleOut need not include serial.\n'
            '        let mut serial = serial_16550::SerialPort::<syscall::io::Pio<u8>>::new(0x3F8);\n'
            '        serial.init();\n'
            '        serial.write(b"\\nBOOT_PROOF:bootloader:");\n'
            '        serial.write(identity.as_bytes());\n'
            '        serial.write(b"\\n");\n'
            '    }\n',
        )


if __name__ == "__main__":
    main()
