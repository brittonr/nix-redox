"""Import OCaml binding constants from target Clang IR, never by running target code.

The names and feature sets mirror Eio 1.6 and iomux 0.4's discover.ml files.
CC is ocamlCross.targetCC, including its relibc sysroot and C11 headers.
"""

import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile


CC = shlex.split(os.environ["CC"])
FLAGS = [
    "-D_LARGEFILE64_SOURCE", "-D_XOPEN_SOURCE=700", "-D_DARWIN_C_SOURCE",
    "-D_GNU_SOURCE", "-D_BSD_SOURCE", "-D__BSD_VISIBLE",
    "-Werror=implicit-function-declaration",
]


def constants(directory, includes, required, optional=()):
    source = "".join(f"#include <{header}>\n" for header in includes)
    for name, expression in required.items():
        source += f"const long long ocaml_redox_{name} = (long long)({expression});\n"
    for name in optional:
        source += (
            f"#ifdef {name}\n"
            f"const long long ocaml_redox_{name} = (long long)({name});\n"
            "#endif\n"
        )
    with tempfile.TemporaryDirectory() as temp:
        cfile = Path(temp) / "constants.c"
        irfile = Path(temp) / "constants.ll"
        cfile.write_text(source)
        subprocess.run(CC + FLAGS + ["-S", "-emit-llvm", str(cfile), "-o", str(irfile)], check=True)
        values = dict(re.findall(
            r"^@ocaml_redox_(\w+)\s*=.*?\bconstant i64 (-?\d+)\b",
            irfile.read_text(), re.MULTILINE,
        ))
    missing = required.keys() - values.keys()
    if missing:
        raise RuntimeError(f"Target compiler did not emit required constants: {sorted(missing)}")
    directory.mkdir(parents=True, exist_ok=True)
    lines = [f"let {name.lower()} = {values[name]}" for name in required]
    lines += [
        f"let {name.lower()} = " + (f"Some ({values[name]})" if name in values else "None")
        for name in optional
    ]
    (directory / "config.ml").write_text("\n".join(lines) + "\n")


def has_ppoll():
    # This is the same compile-and-link feature test as iomux's configurator.
    # A failed test selects its genuine upstream poll backend, not an emulation.
    with tempfile.TemporaryDirectory() as temp:
        cfile = Path(temp) / "ppoll.c"
        cfile.write_text(
            "#define _GNU_SOURCE\n#include <poll.h>\n#include <stddef.h>\n"
            "int main(void) { struct pollfd fds = {0}; struct timespec ts = {0};\n"
            "return ppoll(&fds, 0, &ts, NULL); }\n"
        )
        result = subprocess.run(
            CC + FLAGS + [str(cfile), "-o", str(Path(temp) / "ppoll")],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        if result.returncode:
            sys.stderr.write("iomux: target ppoll unavailable; selecting poll:\n")
            sys.stderr.write(result.stdout.decode(errors="replace"))
        return result.returncode == 0


def main():
    output = Path(sys.argv[1])
    constants(output / "eio_unix", ["errno.h"], {}, ["ENOTCAPABLE"])
    names = [
        "O_RDONLY", "O_RDWR", "O_WRONLY", "O_APPEND", "O_CLOEXEC", "O_CREAT",
        "O_DIRECTORY", "O_EXCL", "O_NOCTTY", "O_NOFOLLOW", "O_NONBLOCK",
        "O_SYNC", "O_TRUNC", "AT_FDCWD", "AT_SYMLINK_NOFOLLOW", "IOV_MAX",
    ]
    constants(
        output / "eio_posix",
        ["errno.h", "sys/types.h", "sys/stat.h", "fcntl.h", "limits.h", "sys/socket.h"],
        dict(zip(names, names)), ["O_DSYNC", "O_RESOLVE_BENEATH", "O_PATH"],
    )
    names = ["POLLIN", "POLLPRI", "POLLOUT", "POLLERR", "POLLHUP", "POLLNVAL"]
    constants(output / "iomux", ["poll.h"], {
        **dict(zip(names, names)), "sizeof_pollfd": "sizeof(struct pollfd)",
    })
    ppoll = has_ppoll()
    with (output / "iomux" / "config.ml").open("a") as stream:
        stream.write(f"let has_ppoll = {str(ppoll).lower()}\n")
    (output / "iomux" / "config.h").write_text(
        "#define HAS_PPOLL\n" if ppoll else "/* target uses poll */\n"
    )


if __name__ == "__main__":
    main()
