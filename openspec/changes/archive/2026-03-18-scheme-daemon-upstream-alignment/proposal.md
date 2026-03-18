## Why

Our four scheme daemons (stored, profiled, build_proxy, virtio-fsd) diverge from upstream Redox daemon patterns in handle ID allocation, null namespace security, fevent support, and resource lifetime management. The upstream randd daemon demonstrates the correct patterns — wrapping handle IDs with collision detection, calling `setrens(0, 0)` after init, implementing fevent. Our daemons were written before some of these patterns were established in our codebase (e.g., build_proxy's `root_fd` pattern) and nobody went back to align them.

## What Changes

- Handle ID allocation in all four daemons: switch from bare `fetch_add(1, Relaxed)` to wrapping with collision detection (matching randd's pattern)
- Null namespace for stored and profiled: adapt FileIoWorker to use `root_fd` bypass (already proven in build_proxy), then call `setrens(0, 0)` after scheme registration
- fevent support for stored, profiled, and build_proxy: implement fevent returning appropriate EventFlags (matching randd and virtio-fsd patterns)
- FileIoWorker cache eviction: add max-size cap to the `BTreeMap<PathBuf, fs::File>` file descriptor cache
- build_proxy handle ID: move global `static NEXT_HANDLE_ID` to per-instance field on `BuildFsHandler`

## Capabilities

### New Capabilities
- `handle-id-safety`: Wrapping handle ID allocation with collision detection and reserved-range avoidance across all scheme daemons
- `null-namespace-security`: Null namespace enforcement for stored and profiled via root_fd bypass in FileIoWorker
- `fevent-support`: Event flag reporting for stored, profiled, and build_proxy scheme handlers
- `io-worker-eviction`: Bounded file descriptor cache in FileIoWorker with LRU-style eviction

### Modified Capabilities

## Impact

- `snix-redox/src/file_io_worker.rs` — add root_fd support and cache eviction
- `snix-redox/src/stored/handles.rs` — handle ID wrapping
- `snix-redox/src/stored/scheme.rs` — fevent, setrens after init
- `snix-redox/src/stored/mod.rs` — pass root_fd to HandleTable
- `snix-redox/src/profiled/handles.rs` — handle ID wrapping
- `snix-redox/src/profiled/scheme.rs` — fevent, setrens after init
- `snix-redox/src/build_proxy/handler.rs` — handle ID wrapping, move static to instance field
- `nix/pkgs/system/virtio-fsd/src/scheme.rs` — handle ID wrapping
