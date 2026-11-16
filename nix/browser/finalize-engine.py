#!/usr/bin/env python3
"""Finalize pinned engines with correct wasm32 pointer, PTY read and proxy bridges.

C/EM_JS passes i32 addresses as signed JS numbers, including valid heap addresses
above 2 GiB. QEMU also relies on nonblocking TTY reads returning EAGAIN instead
of waiting for more input after a partial read. Synchronous proxy completion
must signal its stack-allocated condition before the waiter can observe it.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import shutil

FILES = ("out.js", "qemu-system-x86_64.wasm", "qemu-system-x86_64.worker.js")
TRANSFORM = "redox-wasm32-runtime-v4"
BRIDGE_SHA256 = "3dc0384157ceae276fcff3c3ee0f69d33a63724e30ea66f36179cea419022f8a"
FIXED_MEMORY = 3072 * 1024 * 1024


def read_u32(data, position):
    value = 0
    for shift in range(0, 35, 7):
        if position >= len(data):
            raise ValueError("truncated Wasm integer")
        byte = data[position]
        position += 1
        value |= (byte & 127) << shift
        if byte < 128:
            if value > 0xFFFFFFFF:
                raise ValueError("oversized Wasm integer")
            return value, position
    raise ValueError("invalid Wasm integer")


def encode_u32(value):
    encoded = bytearray()
    while True:
        byte = value & 127
        value >>= 7
        encoded.append(byte | (128 if value else 0))
        if not value:
            return encoded


def read_name(data, position):
    size, position = read_u32(data, position)
    if position + size > len(data):
        raise ValueError("truncated Wasm name")
    return bytes(data[position:position + size]), position + size


def sections(wasm):
    if wasm[:8] != b"\0asm\x01\0\0\0":
        raise ValueError("unsupported Wasm module")
    position, found = 8, []
    while position < len(wasm):
        section = wasm[position]
        length, start = read_u32(wasm, position + 1)
        end = start + length
        if end > len(wasm):
            raise ValueError("truncated Wasm section")
        found.append((section, position, start, end))
        position = end
    return found


def function_indices(wasm, layout):
    # Pinned Emscripten imports only functions and its shared memory.
    imported, names = 0, {}
    for section, _, start, end in layout:
        if section == 2:
            count, position = read_u32(wasm, start)
            for _ in range(count):
                _, position = read_name(wasm, position)
                _, position = read_name(wasm, position)
                kind = wasm[position]
                position += 1
                if kind == 0:
                    _, position = read_u32(wasm, position)
                    imported += 1
                elif kind == 2:
                    flags, position = read_u32(wasm, position)
                    _, position = read_u32(wasm, position)
                    if flags & 1:
                        _, position = read_u32(wasm, position)
                else:
                    raise ValueError("pinned Wasm import ABI changed")
            if position != end:
                raise ValueError("unexpected Wasm import section data")
        elif section == 0:
            name, position = read_name(wasm, start)
            if name != b"name":
                continue
            while position < end:
                kind = wasm[position]
                size, position = read_u32(wasm, position + 1)
                stop = position + size
                if kind == 1:
                    count, position = read_u32(wasm, position)
                    for _ in range(count):
                        index, position = read_u32(wasm, position)
                        label, position = read_name(wasm, position)
                        names[label.decode()] = index
                position = stop
    return imported, names


def sync_proxy_signal_order(wasm):
    # Pinned Emscripten 3.1.50 emscripten_proxy_finish and cancel_ctx store the
    # final state, unlock ctx->sync.mutex and only then signal ctx->sync.cond.
    # That context lives on the waiting thread's stack: the waiter can observe
    # the state after the unlock, return and reuse the stack, so the main thread
    # signals freed memory and busy-waits forever inside checkMailbox. Move only
    # the unlock after the signal, in the same Asyncify-normal block shape.
    layout = sections(wasm)
    imported, names = function_indices(wasm, layout)
    try:
        unlock = encode_u32(names["__pthread_mutex_unlock"])
        signal = encode_u32(names["pthread_cond_signal"])
        targets = {names[name] - imported: name for name in ("emscripten_proxy_finish", "cancel_ctx")}
    except KeyError as error:
        raise ValueError(f"pinned proxy function missing: {error}") from None
    release = b"\x20\x02\x10" + unlock + b"\x21\x02"
    after_release = b"\x20\x00\x41\x28\x6a\x21\x00"
    signal_call = b"\x20\x00\x10" + signal + b"\x21\x01\x41\x01\x23"
    code = [entry for entry in layout if entry[0] == 10]
    if len(code) != 1:
        raise ValueError("pinned Wasm code section missing")
    _, header, start, end = code[0]
    count, position = read_u32(wasm, start)
    bodies = []
    for index in range(count):
        size, position = read_u32(wasm, position)
        body = bytes(wasm[position:position + size])
        position += size
        if index in targets:
            if body.count(release + after_release) != 1 or body.count(signal_call) != 1:
                raise ValueError(f"pinned {targets[index]} proxy completion changed")
            first = body.index(release + after_release)
            second = body.index(signal_call)
            state, cursor = read_u32(body, second + len(signal_call))
            state = encode_u32(state)
            tail = b"\x41\x01\x46\x0d\x03\x1a\x20\x01\x21\x00\x0b"
            if body[cursor:cursor + len(tail)] != tail or first > second:
                raise ValueError(f"pinned {targets[index]} signal block changed")
            resume = cursor + len(tail)
            if body[resume:resume + 1 + len(state) + 3] != b"\x23" + state + b"\x45\x0d\x01":
                raise ValueError(f"pinned {targets[index]} completion exit changed")
            body = (body[:first] + b"\x01" * len(release) + body[first + len(release):resume]
                    + b"\x23" + state + b"\x45\x04\x40\x20\x02\x10" + unlock + b"\x1a\x0b" + body[resume:])
            del targets[index]
        bodies.append(encode_u32(len(body)) + body)
    if position != end or targets:
        raise ValueError("pinned Wasm code section shape changed")
    content = encode_u32(count) + b"".join(bodies)
    patched = wasm[:header] + b"\x0a" + encode_u32(len(content)) + content + wasm[end:]
    return bytearray(patched), ["emscripten_proxy_finish", "cancel_ctx"]


def fixed_memory(source, wasm):
    # Pinned Emscripten imports only functions and one shared wasm32 memory.
    # Raise its fixed import limits and JS constructor together, without
    # rewriting instructions or enabling growth. Unknown ABI shapes fail closed.
    if wasm[:8] != b"\0asm\x01\0\0\0":
        raise ValueError("unsupported Wasm module")
    position = 8
    before = None
    pages = FIXED_MEMORY // 65536
    encoded = encode_u32(pages)
    while position < len(wasm):
        section = wasm[position]
        length, position = read_u32(wasm, position + 1)
        end = position + length
        if end > len(wasm):
            raise ValueError("truncated Wasm section")
        if section == 2:
            count, position = read_u32(wasm, position)
            for _ in range(count):
                names = []
                for _ in range(2):
                    size, position = read_u32(wasm, position)
                    names.append(bytes(wasm[position:position + size]))
                    position += size
                if position >= end:
                    raise ValueError("truncated Wasm import")
                kind = wasm[position]
                position += 1
                if kind == 0:
                    _, position = read_u32(wasm, position)
                    continue
                if kind != 2 or names != [b"env", b"memory"] or before is not None:
                    raise ValueError("pinned Wasm import ABI changed")
                flags, position = read_u32(wasm, position)
                minimum_start = position
                minimum, position = read_u32(wasm, position)
                maximum_start = position
                maximum, position = read_u32(wasm, position)
                if flags != 3 or minimum != maximum or minimum not in (36800, pages):
                    raise ValueError("pinned shared fixed-memory limits changed")
                if maximum_start - minimum_start != len(encoded) or position - maximum_start != len(encoded):
                    raise ValueError("fixed-memory encoding width changed")
                before = {"initialBytes": minimum * 65536, "maximumBytes": maximum * 65536,
                          "growth": False, "shared": True}
                wasm[minimum_start:maximum_start] = encoded
                wasm[maximum_start:position] = encoded
            if position != end:
                raise ValueError("unexpected Wasm import section data")
        elif section == 5:
            count, _ = read_u32(wasm, position)
            if count:
                raise ValueError("unexpected defined Wasm memory")
        position = end
    if before is None:
        raise ValueError("pinned Wasm memory import missing")
    initial = re.compile(r'(var INITIAL_MEMORY = Module\["INITIAL_MEMORY"\] \|\| )(\d+);')
    matches = list(initial.finditer(source))
    if len(matches) != 1 or int(matches[0][2]) != before["initialBytes"]:
        raise ValueError("pinned JS/Wasm initial memory mismatch")
    for key in ("initial", "maximum"):
        if source.count(f'"{key}": INITIAL_MEMORY / 65536') != 1:
            raise ValueError("pinned fixed-memory constructor changed")
    return initial.sub(lambda match: match[1] + str(FIXED_MEMORY) + ";", source), before


def identity(path):
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
            size += len(chunk)
    return {"sha256": digest.hexdigest(), "size": size}


def normalize(source):
    # These are the pinned Emscripten-formatted, handwritten TCG/libffi bridges,
    # not arbitrary program arithmetic. Their shifts by 1/2/3 are heap-address
    # indexing; numeric/BigInt value shifts elsewhere must remain unchanged.
    start = "function report_census_js(t, gp, gn, cp, cn) {"
    end = re.compile(r"^function ffi_prep_closure_loc_js\(closure, cif, fun, user_data, codeloc\) \{.*?^\}", re.M | re.S)
    if source.count(start) != 1:
        raise ValueError("pinned census bridge changed")
    matches = list(end.finditer(source))
    if len(matches) != 1 or matches[0].start() <= source.index(start):
        raise ValueError("pinned closure bridge boundary changed")
    begin, finish = source.index(start), matches[0].end()
    body = source[begin:finish]
    if hashlib.sha256(body.encode()).hexdigest() != BRIDGE_SHA256:
        raise ValueError("pinned manual bridge changed; review address semantics before updating the source binding")
    constructor = "new Uint8Array(HEAP8.buffer, bytes_ptr, bytes_len)"
    body, changes = re.subn(r"(?<!>)>>(?!>)(\s+[123]\b)", r">>>\1", body)
    body = body.replace(constructor, "new Uint8Array(HEAP8.buffer, bytes_ptr >>> 0, bytes_len)", 1)
    source = source[:begin] + body + source[finish:]
    atomic = "PTY_atomicIndex = _malloc(4) >> 2;"
    if source.count(atomic) != 1:
        raise ValueError("pinned PTY atomic bridge changed")
    source = source.replace(atomic, "PTY_atomicIndex = _malloc(4) >>> 2;", 1)
    if "Module.redoxChunkDisk" in source:
        chunk_atomic = "Atomics.store(HEAP32, done >> 2, 1);"
        chunk_unsigned = "Atomics.store(HEAP32, done >>> 2, 1);"
        if source.count(chunk_atomic) + source.count(chunk_unsigned) != 1:
            raise ValueError("pinned chunk completion bridge changed")
        changes += source.count(chunk_atomic)
        source = source.replace(chunk_atomic, chunk_unsigned, 1)
    wait = "PTY_askToWaitAgain(-1);"
    if source.count(wait) != 1:
        raise ValueError("pinned PTY read bridge changed")
    # Pinned Emscripten/musl O_NONBLOCK and WASI EAGAIN. Blocking descriptors
    # retain the PTY suspension path; a nonblocking read must not await input.
    source = source.replace(wait,
        "if (stream.flags & 2048 /* O_NONBLOCK */) throw new FS.ErrnoError(6 /* EAGAIN */);\n    " + wait, 1)
    return source, changes + 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engine", type=Path, help="fresh writable build/import output; never a published tree")
    parser.add_argument("--pins", type=Path, required=True)
    args = parser.parse_args()
    root = args.engine
    pins = json.loads(args.pins.read_bytes())
    declaration = root / "engine-identity.json"
    if not declaration.is_file():
        declaration = root / "engine-pins.json"
    metadata = json.loads(declaration.read_bytes())
    if "runtimeTransform" in metadata:
        raise ValueError("engine has already been finalized")
    for key in ("qemuRevision", "trynixRevision"):
        if metadata.get(key) != pins[key]:
            raise ValueError(f"engine source revision mismatch: {key}")
    inputs = {}
    for name in FILES:
        actual = identity(root / name)
        expected = metadata["files"][name]
        if isinstance(expected, str) and expected.startswith("sha256-"):
            expected = {"sha256": base64.b64decode(expected[7:], validate=True).hex()}
        if any(actual[key] != value for key, value in expected.items() if key in ("sha256", "size")) or "sha256" not in expected:
            raise ValueError(f"engine input provenance mismatch: {name}")
        inputs[name] = actual
    generated = (root / "out.js").read_text()
    fixed, shifts = normalize(generated)
    wasm_name = FILES[1]
    wasm = bytearray(inputs[wasm_name]["size"])
    with (root / wasm_name).open("rb") as binary:
        if binary.readinto(wasm) != len(wasm):
            raise ValueError("Wasm input truncated after verification")
    fixed, input_memory = fixed_memory(fixed, wasm)
    wasm, proxy_completion = sync_proxy_signal_order(wasm)
    payload = fixed.encode()
    metadata.setdefault("schemaVersion", 1)
    metadata.setdefault("kind", "pinned-upstream-artifact-import")
    metadata["inputFiles"] = inputs
    metadata["inputMemory"] = input_memory
    metadata["memory"] = {**metadata.get("memory", {}), "initialBytes": FIXED_MEMORY,
                          "maximumBytes": FIXED_MEMORY, "growth": False, "shared": True}
    metadata["files"] = {**inputs, "out.js": {"sha256": hashlib.sha256(payload).hexdigest(), "size": len(payload)},
                         wasm_name: {"sha256": hashlib.sha256(wasm).hexdigest(), "size": len(wasm)}}
    script = Path(__file__).resolve()
    metadata["runtimeTransform"] = {"name": TRANSFORM, "sourceSha256": identity(script)["sha256"],
        "unsignedHeapShifts": shifts, "nonblockingTtyReads": True, "syncProxySignalBeforeUnlock": proxy_completion,
        "invocation": "python3 source/finalize-engine.py ENGINE --pins source/engine-pins.json"}
    # All validation precedes writes. Build failure cannot publish a partial tree.
    (root / "out.js").write_bytes(payload)
    (root / wasm_name).write_bytes(wasm)
    source = root / "source"
    source.mkdir(exist_ok=True)
    destination = source / "finalize-engine.py"
    if destination.resolve() != script:
        shutil.copyfile(script, destination)
    encoded = json.dumps(metadata, indent=2) + "\n"
    (root / "engine-identity.json").write_text(encoded)
    (source / "build-provenance.json").write_text(encoded)
    print(json.dumps({"transform": TRANSFORM, "unsignedHeapShifts": shifts, "files": metadata["files"]}))


if __name__ == "__main__":
    main()
