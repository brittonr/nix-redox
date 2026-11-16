# Local browser demo

The live demo runs the x86_64 Redox kernel, RedoxFS and userspace locally in
QEMU compiled to WebAssembly. It is not a recording, a remote VM, or the direct
WASM evaluator. Guest networking is disabled. The landing-page recordings remain
available when browser isolation or VM startup fails.

The landing page and live workspace share `site/identity.css`, adapted from
Kiln's neutral paper/ink palette, local typography, square frames and semantic
status colors. Its MIT attribution is retained in the stylesheet; no Kiln
backend or external font service is embedded. The live rail navigates actual
sections, including the bundled package actions before the VM starts. On narrow
screens, **Menu** expands navigation and **Escape** closes it. **Appearance**
uses the same saved light/dark preference as the landing page.

## Build and serve

```sh
nix build .#browser-image .#browser-site
nix run .#browser-serve -- --port 8080 --prefix /redox-preview/
```

Open `http://127.0.0.1:8080/redox-preview/live/`. The local server supplies the
COOP/COEP/CORP headers required by the pinned threaded engine. A directory server
without these headers is not an equivalent deployment. Use HTTPS outside
localhost. Missing isolation, workers, WebAssembly or SharedArrayBuffer produces
an explicit capability failure rather than a pretend guest session.

`browser-image` contains `redox.img`, boot files, the machine contract, and the
mandatory fixture catalog. The serial profile contains Ion, Bash, uutils, the
seed Snix CLI, an offline ripgrep cache, and the A → B → C runtime-closure
fixture. It omits guest network, graphics, audio and USB drivers. The separate
`browser-graphical-image` contains the Orbital workload.

Boot and Reset create a new writable session. Stop destroys its iframe and
workers. Reset does not preserve installed packages, builds, configuration
changes, or writes. Verified immutable download bytes may remain in a bounded
cache; a cached download is not retained guest state. A stopped or replaced
session cannot execute another guest command.

## Using the showcase

Press **Boot**, then wait for **Ready**. Loading shows real download byte counts;
booting waits for the guest readiness marker. The elapsed clock is measured time,
not a completion estimate. Expand **Startup asset details** for per-file download
and verification information without hiding the main terminal behind ROM logs.

The **Shell command** editor accepts one command or a multiline Bash script.
Example buttons only fill the editor; **Run command** starts actual guest
execution and displays its output, exit status and elapsed time. Each submission
runs in a child shell in the same guest filesystem; use the terminal for
interactive programs or persistent changes to shell working directory and
environment. Source is limited to 64 KiB and editor commands have a two-minute
timeout. A nonzero command exit is reported without disabling the ready guest.

Named busy states explain when an action owns serial input. During that action,
terminal keystrokes and competing guest actions are paused; **Stop** remains
available. The independent WASM evaluator does not acquire the guest channel;
its explicit **Run in Redox** action does. The terminal fits its column count to
the available width without shrinking its text.

The serial shell starts in its writable home after switchroot, not the initfs
directory inherited from init. Ordinary relative commands such as `pwd`, `ls`
and creating a file therefore operate on the real guest filesystem. Fresh-build
actions require a new declared input each time; an existing output is rejected.


## Offline guest contract

The actual serial shell emits
`REDOX_BROWSER_DEMO_READY:v1:shell=1:snix=1:initial=1` only after Bash, Snix
arithmetic, the initial generation/configuration, absent build outputs, disabled
networking and the empty user package profile have been checked.

The UI can evaluate an expression, build a fresh output from a declared input,
install and execute bundled ripgrep, and run the mandatory offline suite. The
suite performs install/execute/remove, two input-specific builds, a local
hostname rebuild, generation-state checks and the actual rollback CLI. It
validates state and bytes, not merely command text or a banner. Reset between
whole-suite runs: the suite intentionally changes the guest generation and
creates outputs. Reusing a build input is not a fresh build.

Commands cross the serial path as encoded data and complete with a fresh token
and an actual guest exit status. Output from an old session, an echoed command,
a missing mandatory result, FAIL, SKIP, or a timeout cannot count as success.
The serial editor uses the terminal's native clipboard handling: on Linux,
paste with **Ctrl+Shift+V**. **Ctrl+V** sends the canonical literal-next byte,
not clipboard text. Selecting text and pressing Ctrl+C copies it; without a
selection, Ctrl+C sends byte 0x03. The debug console is not a full POSIX TTY
and does not turn that byte into a guest SIGINT.

The fixture catalog is `nix/redox-system/fixtures/browser-demo/catalog.json`.

## Boot selection and native TCG

Backend selection and acceleration are independent. `--qemu` alone means forced
TCG; `--qemu --accel auto` explicitly requests host-aware QEMU acceleration.
`--accel` overrides `REDOX_VM_ACCEL`, which overrides the configured default.
The general native runners use `qemu64`, `thread=single`, and the configured
`tcgCpus` for TCG unless `--cpus` is supplied. KVM uses `host`; Cloud Hypervisor
requires usable KVM and rejects TCG rather than silently changing backend.

```sh
nix run .#boot-test -- --qemu --accel tcg --cpus 1 \
  --timeout 300 --artifacts ./tcg-evidence
```

The shell milestone requires a freshly executed serial nonce. Artifacts retain
argv, firmware/image identities, serial/VMM logs, elapsed time and exit status.
The startup service explicitly connects stdin/stdout/stderr to the serial debug
scheme; init's logger is not an input terminal.

`/boot.autoBoot` controls menu selection independently of `/boot.liveMode`:

| autoBoot | liveMode | Selection | Storage |
|---|---|---|---|
| false | false | interactive graphical menu | normal disk |
| true | false | unattended | normal disk |
| false | true | interactive graphical menu | filesystem copied into RAM |
| true | true | unattended | filesystem copied into RAM |

`liveMode` defaults to false. `autoBoot` defaults to `liveMode` for existing live
images; an explicit value wins. An explicit bootloader package overrides variant
selection and must implement both requested behaviors. Serial-only firmware can
bypass the graphical menu. Live mode needs memory for the filesystem allocation
and working set; unattended selection alone does not allocate a live filesystem.

## Engines and optional backends

`nix/browser/engine-pins.json` pins QEMU, TryNix, the imported engine artifacts,
and the Emscripten SDK image. Native QEMU uses the matching source and generic
host-tick behavior. The source recipe uses Docker/Emscripten, not a Nix-native
WASM compiler. Linked-library sources and SDK identity are pinned; online apt
build tools mean the recipe is explicitly non-hermetic, not byte-reproducible.

The shared browser/native machine contract uses **one vCPU with
`tcg,thread=multi`**. This is not a second guest CPU: the pinned WASM fork
initializes its per-vCPU translation state only in the MTTCG loop. Forcing its
round-robin `thread=single` loop traps before firmware serial output. This
restriction does not apply to the ordinary native-only runners above.

The browser profiles allocate 1024 MiB of guest RAM. The pinned engine accepts
at most 2047 MiB; publication and manifest loading reject an out-of-range or
inconsistently encoded allocation. Guest RAM is separate from the engine's
WASM linear memory, expanded disk, and retained browser buffers.

Both imported and source-built factories pass through the version-bound
`finalize-engine.py` step. It fixes unsigned wasm32 heap addressing and preserves
nonblocking PTY reads, including partial reads followed by EAGAIN. It also
repairs the pinned Emscripten runtime's synchronous proxy completion:
`emscripten_proxy_finish` and `cancel_ctx` unlocked the waiting thread's
stack-allocated context before signaling its condition variable. A waiter could
return in that window, so the page's main thread signaled reused stack memory
and spun inside its proxied-call mailbox, freezing the page and its debugger
during sustained serial I/O. The transform signals before unlocking in both
functions and fails if their pinned bytecode changes. The delivered
JavaScript factory and Wasm import both declare fixed **3072 MiB** shared linear
memory, with growth disabled; valid addresses above 2 GiB remain unsigned.
`inputMemory` and `inputFiles` preserve the original limits and verified artifact
digests; `memory` and `files` describe the finalized limits and actual shipped
JS/WASM/worker bytes. The transform and audited bridge-source hash ship with the
sources. Apply it only to a fresh writable build/import output, never a published
revision tree.

The imported baseline engine supports the serial preload route. Lazy block I/O
and the framebuffer/input frontend require the source-built extended engine:

```sh
nix run .#browser-build-engine -- /absolute/path/to/browser-engine extended
```

The output path must not already exist. The output records actual engine
hashes, numbered patches and copied C overlays, the SDK image, sources and
license notices. Do not claim the imported engine has extension hooks merely
because its VGA device model is compiled.

Rebuild the extended engine when its C device patches change. Runtime
finalization does not upgrade a compiled display or block-device ABI; use an
engine built from the matching patches, not an older bundle with a new wrapper.

To assemble an extended release, set `REDOX_BROWSER_ENGINE` to that output and
use the exported constructor:

```sh
nix build --impure --expr '
let
  f = builtins.getFlake ("git+file:" + toString ./.);
  engine = builtins.path {
    path = builtins.getEnv "REDOX_BROWSER_ENGINE";
    name = "redox-browser-engine";
  };
in f.legacyPackages.x86_64-linux.mkBrowserSite { inherit engine; }
'
```

For a graphical release, additionally pass
`guestImage = f.packages.x86_64-linux.browser-graphical-image` and
`machine = ./nix/browser/graphical-machine.json`. The graphical machine has a
separate identity, fixed firmware-requested display mode, PS/2 keyboard and
pointer devices, disabled USB/audio/network, and its own measured resource
requirements. CSS/full-screen scaling does not change the guest display mode.
The serial diagnostic path remains available if display initialization fails.

The lazy backend uses content-addressed chunks, a bounded verified read cache,
bounded in-flight fetches, and a bounded private write overlay. Partial writes
preserve untouched bytes. Missing, truncated or corrupt chunks fail explicitly;
a failed fetch is not substituted with zeros. Overlay exhaustion is an I/O
failure, not implicit eviction of guest writes. Only chunk-capable engine
bundles include the alternate chunked disk. Preload remains an independent path.

A rejected guest root-disk write fails its owning VM and rejects pending
commands promptly. Reset discards the failed session's partial overlay and
starts from the pristine disk; it does not retry or silently accept the write.

## Downloaded guest packages

The deployment is entirely static. Browser HTTP(S) Fetch downloads immutable
cache objects, and a versioned serial request/response protocol delivers them
to a foreground Snix receiver inside Redox. No guest NIC, 9p mount, WebSocket
service, server-hosted VM or external network bridge is involved. The receiver
writes the mounted guest filesystem; browser code never edits a live RedoxFS
disk image.

A browser fetches only the selected cache root's pinned transport inventory and
supplies those bytes to an explicit guest receive/import/install flow. This is
not a guest NIC and does not expose arbitrary host paths. Source, staging and
installed data are separate; cancellation/reset invalidates the transfer's
session identity. Payload sizes and hashes are checked before use, and Snix
traverses the truthful narinfo reference graph.

The downloadable `browser-cache` contains fd, which is not the bundled ripgrep
fixture. See [binary-cache.md](binary-cache.md) for package-index versions,
target evidence, closure validation, and installation behavior.

Run the actual download/import/install/failure/reset gate against a built site:

```sh
nix run .#browser-cache-smoke-test -- ./serial-site --output ./cache-evidence
```

The completed Chromium 148/Linux gate for bundle `9f3d5fe02da6` passed all
29 phases, including real execution, verified guest/browser reuse and 12
failure/lifecycle cases. Browsing fetched no package payloads. Both reuse paths
made no cache-object network requests; a reset guest still needs serial delivery
from the verified browser cache.

| Downloaded package | Serial object bytes | UI-reported transfer/install (s) |
|---|---:|---:|
| fd 10.2.0 | 1,083,459 | 1170.90 |
| Three-member runtime closure fixture | 771,413 | 910.50 |

These are loopback measurements, not throughput promises. The serial transport
is slow even when HTTP objects are cached. Browser inventory bytes and mounted
guest object bytes were measured independently and agreed. Per-transfer limits
are one owner, 8 KiB frames, 4 MiB descriptor, 128 MiB object, 256 MiB selected
closure and 256 files; immutable-object verification is not publisher trust.


## Direct Snix-WASM playground

Direct evaluation works without starting the VM. It runs the pinned Snix
evaluator in a separate, cancellable worker and uses the bundled POSIX source
tree under `/playground/v1`. Arithmetic, attributes, lists, functions and the
bundled relative import are supported. Host filesystem/environment access,
network fetching, arbitrary flakes/nixpkgs and build execution are not supplied.
Unsupported I/O fails; it is not replaced with invented values. Trace collection
is unavailable and is stated as such.

Direct results and guest results are separate panels. **Run in Redox** is an
explicit second operation, available only for a ready live guest. Diagnostics
carry source ranges; expression/output limits and worker cancellation bound the
direct evaluator. The browser exercise compares portable fixtures against actual
guest Snix and checks cancellation without killing the VM.

## Immutable deployment and snapshots

`sourceRevision` identifies the source input. `runtimeRevision` identifies the
guest/runtime contract. `revision` is the complete bundle identity, including
frontend/static files, evaluator, notices and optional snapshot metadata.
Changing an engine or frontend under the same source label therefore creates a
different immutable saved URL.

Mutable `/live/` is a small bootstrap: it fetches `channel.json` without caching,
verifies the selected manifest's size and SHA-256, and navigates to
`revisions/<bundle-revision>/live/`. Upload all immutable assets before switching
the channel pointer; preserve old revision URLs. `_headers`, the local server
and the isolation service-worker path distinguish mutable entrypoints from
immutable content. No deployment relies on epoch-normalized mtimes to identify
changed JavaScript or WASM.

Snapshots are optional and cannot replace the cold-boot proof. Capture requires
successful matching native and browser cold evidence, the exact raw image,
firmware/EFI/ROM identities and engine/machine bindings. A guest flush and
fresh-token reader handshake precede QEMU's pre-switchover pause; completed
migration drains/inactivates the block graph before the disk is copied. The
bundle records state, disk, firmware, provenance and compatibility identities.
The source is not resumed while its frozen disk is copied.

```sh
nix run .#browser-native-proof -- --out ./native-cold
nix run .#browser-smoke-test -- --output ./browser-cold
nix run .#browser-snapshot -- \
  --native-evidence ./native-cold/evidence.json \
  --browser-evidence ./browser-cold/evidence.json \
  --out ./snapshot-bundle
```

Pass the resulting bundle through `mkBrowserSite { snapshot = ...; }`. Incompatible
or unavailable snapshot state takes an explicit cold path; resumed readiness
requires a fresh token, not stale terminal output. Captured entropy is not fresh
entropy. The snapshot path does not enable guest networking.

Browser admission checks independently change captured engine, CPU, RAM,
firmware, disk and machine identities while retaining valid object/envelope
hashes. Incompatible captures must fail before creating an emulator document.

## Verification and resource reporting

`browser-smoke-test` serves the deployable tree with production-equivalent
headers and a non-root URL prefix, then drives real Chromium. It checks fresh
nonce-derived guest results, mandatory offline behavior, reset and repeated
sessions, stopped-worker quiescence, missing/corrupt assets and broken boot,
missing Snix, browser-versus-guest elapsed clocks, and optional resume behavior.
It retains raw serial, manifest/source/runtime/bundle identities, browser version,
phase timings, diagnostics and measured resources. Desktop validation also needs
actual framebuffer output and keyboard/pointer interaction, not a canvas alone.

Missing Snix or the serial decoder must return command-not-found status 127,
not an apparently successful empty evaluation. The terminal stays available,
and Reset restores both tools and permits a fresh nonce-derived evaluation.
Fault setup is noninteractive even for write-protected guest binaries; the
session's boot deadline must precede the outer harness execution deadline.

A 64-bit HPET clock source uses the free-running counter rather than counting
delivered timer interrupts. Software emulation can
coalesce interrupts without stopping that counter. The external clock check
warms both the sleep executable and its nonzero timer path, then uses a timed
`/bin/sleep 0` control instead of a shell builtin. Raw elapsed time and control
overhead remain in the evidence even when the assertion fails. The default
16-second interval reduces the relative effect of command/scheduling jitter
without widening the 35% correctness tolerance. The fault self-test uses a real
baseline-length sleep against a four-times-longer expectation; neither its
proportional-fault check nor the normal tolerance is relaxed.

The failed four-second lazy and resumed-clock invocations remain failed in the
retained evidence. Both complete workloads passed with the longer baseline and
detected the injected fault; no guest clock code was changed in response to
those short samples.

Clock-corrected preload measurements on the same Linux/Chromium 148 runner,
served over loopback with fresh browser contexts:

| Mode | Ready (s) | Recorded response bodies (MiB) | Sampled aggregate peak PSS (GiB) |
|---|---:|---:|---:|
| Cold boot | 69.15 | 327.42 | 3.41 |
| Native snapshot resume | 3.44 | 1114.04 | 3.66 |

These are narrow shell/Snix/clock smoke measurements, not the full fixture
runtime. Response-body totals come from main-page Resource Timing entries;
PSS is sampled across this Chromium instance. Both modes use 1024 MiB guest
RAM and fixed 3072 MiB Wasm memory. The pristine logical disk is 896 MiB and
its compressed transfer is 305.39 MiB. Resume fetches the captured raw disk
plus 195.58 MiB of VM state: lower CPU startup time does not imply a smaller
download. The corresponding bundle IDs start `a80f290f055a` (cold) and
`6dd2e9ad6cd6` (resume).

The optional backend gates take an explicit deployment tree, built with the
extended engine and the corresponding machine/image:

```sh
nix run .#browser-chunk-smoke-test -- ./extended-site --output ./chunk-evidence
nix run .#browser-graphical-smoke-test -- ./graphical-site --output ./orbital-evidence
```

The chunk gate compares actual preload/lazy guest behavior, cold/warm transfers,
cache/overlay bounds, I/O failures, and session isolation. The graphical gate
types a fresh Snix expression and the offline suite through PS/2 into orbterm,
then independently reads the resulting guest files over serial. Its framebuffer
PNGs still require manual layout/pointer/wheel review. Graphical demo login is
`root` / `redox`; these are intentionally public offline-demo credentials.
Ordinary `browser-smoke-test --disk-backend lazy` also runs its guest workflow
against the chunk backend; snapshot restore always uses its captured preload disk.

Completed serial preload/lazy workloads on the same runner and `a80f290f055a`
engine/image cohort measured:

| Backend | Cold transfer (MiB) | Warm transfer (MiB) | Sampled peak RSS (GiB) | Sampled peak PSS (GiB) |
|---|---:|---:|---:|---:|
| Preload | 330.87 | 318.47 | 6.31 | 6.19 |
| Lazy | 157.82 | 154.43 | 4.73 | 4.62 |

Transfer is ResourceTiming `transferSize`, including headers where exposed;
zero can mean HTTP-cache or service-worker delivery. Peaks span each complete
cold/warm/reset workload, not individual transfers or guest-only memory. These
separate sampled runs do not establish a universal or causal performance gain.
The later frame-only write-error fix was verified separately with unchanged
engine, firmware, machine and disk assets.

Disk file probes use installed Bash, the seed Snix multicall raw-file hash
entry and `browser-demo-flush`; they do not assume standalone `head`, `dd`,
`find`, `sha256sum` or `sync` applets. The byte-correctness fixture is ASCII.
Quota writes use Bash `read -N` in the C locale with fresh `/scheme/rand` bytes
and 1 MiB buffers, omitting NULs and attempting at most 68 MiB against the
unchanged 64 MiB overlay limit. The gate requires a real backend ENOSPC write,
prompt session failure, no retained command/frame, and a fresh reset that
discards the partial file and executes a new nonce. A command timeout alone
cannot pass quota acceptance.

Report these quantities separately: compressed transfer bytes, logical disk
bytes, guest RAM, observed WASM linear memory, retained asset/cache/overlay
buffers, and browser/process memory. JS heap is not total VM memory. Linux RSS
and PSS observations have shared-memory and sampling caveats; unavailable APIs
are recorded as unavailable. Cold download, warm cache, cold boot and snapshot
resume are distinct measurements. The fixture catalog records the Chromium 148,
Linux x86_64/Ryzen 9 9950X3D baseline and its exact serial/graphical bundle IDs.
Completed proxy-finish-repaired-engine gates on that runner measured:

| Bundle / mode | Max ready (s) | Max first command (s) | Max fixtures (s) | Sampled peak RSS (GiB) | Sampled peak PSS (GiB) |
|---|---:|---:|---:|---:|---:|
| `74a06df1cd95` / serial | 86.95 | 22.47 | 415.80 | 4.37 | 4.07 |
| `f2ed1dda1a2d` / Orbital | 103.68 | 18.30 | 669.08 | 4.69 | 4.37 |

Serial passed 53 phases with two complete 11-fixture flows; Orbital passed 31
phases with all 11 fixtures, nine graphical command runs and five session
lifecycles. Memory peaks span each full invocation, not guest-only memory.
The catalog retains its earlier baseline and unchanged ceilings.

Snapshot bundle `fd371d7ce585` shares the serial bundle's runtime. Its completed
resumed invocation passed all 11 fixtures, three resets and 14 admission/tool
cases. Acceptance combines the matched native/cold proof and this resumed
invocation rather than relabeling the earlier full invocation as successful.

An earlier concurrently loaded Orbital invocation lost command characters
despite zero browser input-ring overflows. Its cause is unproven and its failed
evidence is retained; the completed rerun does not establish lossless PS/2 input
under arbitrary host contention.

The smoke gate enforces catalog ceilings: 256 s readiness, 39 s first command,
900 s mandatory fixtures, 409 MiB compressed disk, 1 GiB logical disk, 1024 MiB
guest RAM, fixed 3 GiB Wasm memory, and sampled aggregate 8 GiB RSS / 7 GiB PSS.
The catalog states the rounding/headroom calculation; these are regression
envelopes derived from Redox, not performance promises for other hardware.
Missing measured policy is an error. A configured RAM size is not a proven
minimum; 512 MiB remains an experiment until its complete workload is exercised.

Execution evidence currently covers Chromium 148 on Linux x86_64. Firefox,
Safari, mobile browsers and other host platforms are untested; passing feature
detection alone is not a tested-support claim.

The repository's MIT license does not replace upstream licenses. Distributed
QEMU, GLib, Emscripten, terminal and direct-evaluator artifacts retain their own
notices, corresponding sources and recipes in the release's license/source tree.
