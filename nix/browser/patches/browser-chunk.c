/*
 * Browser chunk protocol for QEMU 8.2 / ktock qemu-wasm
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * This is an Emscripten-only block backend, not a live filesystem adapter.
 * MAIN_THREAD_ASYNC_EM_ASM queues work and returns without a synchronous
 * UI-thread proxy. Fetch promises execute on the browser main thread while
 * the existing QEMU fiber coroutine sleeps on its real-time AioContext timer.
 * A shared-memory atomic mailbox publishes completion after the data copy.
 * No EM_ASYNC_JS unwind can nest into the fork's emscripten_fiber_swap unwind.
 */
#include "qemu/osdep.h"
#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#include <stdatomic.h>
#include "qapi/error.h"
#include "qapi/qmp/qdict.h"
#include "qemu/module.h"
#include "qemu/cutils.h"
#include "qemu/option.h"
#include "qemu/coroutine.h"
#include "qemu/timer.h"
#include "block/block-io.h"
#include "block/block_int.h"

#define CHUNK_MAX_TRANSFER (1024 * 1024)

typedef struct BDRVBrowserChunkState {
    int64_t length;
    char image_id[65];
} BDRVBrowserChunkState;

typedef struct ChunkCompletion {
    _Atomic int done;
    int result;
} ChunkCompletion;

static QemuOptsList chunk_runtime_opts = {
    .name = "browser-chunk",
    .head = QTAILQ_HEAD_INITIALIZER(chunk_runtime_opts.head),
    .desc = {
        { .name = BLOCK_OPT_SIZE, .type = QEMU_OPT_SIZE },
        { .name = "image-id", .type = QEMU_OPT_STRING },
        { }
    },
};

static int chunk_open(BlockDriverState *bs, QDict *options, int flags,
                      Error **errp)
{
    BDRVBrowserChunkState *s = bs->opaque;
    QemuOpts *opts = qemu_opts_create(&chunk_runtime_opts, NULL, 0, errp);
    const char *id;
    int i, ret = -EINVAL;

    if (!opts) {
        return -EINVAL;
    }
    if (!qemu_opts_absorb_qdict(opts, options, errp)) {
        goto out;
    }
    s->length = qemu_opt_get_size(opts, BLOCK_OPT_SIZE, 0);
    id = qemu_opt_get(opts, "image-id");
    if (s->length <= 0 || s->length > 9007199254740991LL ||
        s->length % 512 || !id || strlen(id) != 64) {
        error_setg(errp, "browser-chunk needs sector-aligned size and image-id");
        goto out;
    }
    for (i = 0; i < 64; i++) {
        if (!((id[i] >= '0' && id[i] <= '9') ||
              (id[i] >= 'a' && id[i] <= 'f'))) {
            error_setg(errp, "browser-chunk image-id must be lowercase SHA-256");
            goto out;
        }
    }
    pstrcpy(s->image_id, sizeof(s->image_id), id);
    bs->supported_write_flags = BDRV_REQ_FUA;
    ret = 0;
out:
    qemu_opts_del(opts);
    return ret;
}

/* op: 0=read, 1=write, 2=flush. The caller owns data and mailbox until done.
 * In PROXY_TO_PTHREAD the runtime UI thread remains available to run the
 * asynchronous proxy; it never waits for the emulator thread. The release /
 * acquire pair prevents QEMU seeing unverified or partially copied bytes.
 */
static int coroutine_fn chunk_request(BlockDriverState *bs, int op,
                                     int64_t offset, QEMUIOVector *qiov, int bytes)
{
    BDRVBrowserChunkState *s = bs->opaque;
    ChunkCompletion completion = { .done = 0, .result = -EIO };
    MAIN_THREAD_ASYNC_EM_ASM(({
        const op = $0, offset = $1, iov = $2, bytes = $3, niov = $8;
        const done = $4, result = $5, identity = UTF8ToString($6), size = $7;
        const finish = (status) => {
            HEAP32[result >> 2] = status;
            Atomics.store(HEAP32, done >>> 2, 1);
        };
        (async () => {
            const disk = Module.redoxChunkDisk;
            if (!disk || disk.imageSha256 !== identity || disk.logicalSize !== size) {
                throw new Error('Missing or incompatible browser chunk disk');
            }
            const vectors = [];
            let total = 0;
            for (let i = 0; i < niov; i++) {
                const ptr = HEAPU32[(iov >> 2) + i * 2];
                const length = HEAPU32[(iov >> 2) + i * 2 + 1];
                vectors.push([ptr, length]); total += length;
            }
            if (total !== bytes) throw new Error('Invalid block iovec');
            if (op === 0) {
                const data = await disk.read(offset, bytes);
                if (data.length !== bytes) throw new Error('Short block read');
                let position = 0;
                for (const [ptr, length] of vectors) {
                    HEAPU8.set(data.subarray(position, position + length), ptr);
                    position += length;
                }
            } else if (op === 1) {
                const data = new Uint8Array(bytes);
                let position = 0;
                for (const [ptr, length] of vectors) {
                    data.set(HEAPU8.subarray(ptr, ptr + length), position);
                    position += length;
                }
                await disk.write(offset, data);
            } else {
                await disk.flush();
            }
        })().then(() => finish(0), (error) => {
            const errno = error && error.errno;
            finish(-(Number.isInteger(errno) && errno > 0 && errno < 4096 ? errno : 5));
        });
    }), op, (double)offset, qiov ? qiov->iov : NULL, bytes,
       &completion.done, &completion.result, s->image_id, (double)s->length,
       qiov ? qiov->niov : 0);

    while (!atomic_load_explicit(&completion.done, memory_order_acquire)) {
        qemu_co_sleep_ns(QEMU_CLOCK_REALTIME, 1000000);
    }
    /* JS errors use stable Linux/POSIX-facing numbers; Emscripten libc's
     * numeric errno values differ. Translate before returning into QEMU. */
    switch (-completion.result) {
    case 0: return 0;
    case 5: return -EIO;
    case 16: return -EBUSY;
    case 22: return -EINVAL;
    case 28: return -ENOSPC;
    case 95: return -ENOTSUP;
    case 125: return -ECANCELED;
    default: return -EIO;
    }
}

static int coroutine_fn chunk_io(BlockDriverState *bs, int64_t offset,
                                 int64_t bytes, QEMUIOVector *qiov, int op)
{
    BDRVBrowserChunkState *s = bs->opaque;
    /* The main-thread bridge reads the wasm32 iovec layout, without C bounce
     * buffers. One JS operation covers the entire scatter/gather request, so
     * overlay quota rejection cannot partially commit a QEMU block write.
     */
    QEMU_BUILD_BUG_ON(sizeof(struct iovec) != 8);
    QEMU_BUILD_BUG_ON(offsetof(struct iovec, iov_len) != 4);
    if (offset < 0 || bytes < 0 || bytes > CHUNK_MAX_TRANSFER ||
        offset > s->length || bytes > s->length - offset || qiov->size != bytes) {
        return -EINVAL;
    }
    return chunk_request(bs, op, offset, qiov, bytes);
}

static int coroutine_fn chunk_read(BlockDriverState *bs, int64_t offset,
                                   int64_t bytes, QEMUIOVector *qiov,
                                   BdrvRequestFlags flags)
{
    return chunk_io(bs, offset, bytes, qiov, 0);
}

static int coroutine_fn chunk_write(BlockDriverState *bs, int64_t offset,
                                    int64_t bytes, QEMUIOVector *qiov,
                                    BdrvRequestFlags flags)
{
    /* FUA means committed to this volatile session overlay, not persistence. */
    return chunk_io(bs, offset, bytes, qiov, 1);
}

static int coroutine_fn chunk_flush(BlockDriverState *bs)
{
    return chunk_request(bs, 2, 0, NULL, 0);
}

static int coroutine_fn chunk_discard(BlockDriverState *bs, int64_t offset,
                                      int64_t bytes)
{
    return -ENOTSUP;
}

static int64_t coroutine_fn chunk_length(BlockDriverState *bs)
{
    BDRVBrowserChunkState *s = bs->opaque;
    return s->length;
}

static void chunk_limits(BlockDriverState *bs, Error **errp)
{
    bs->bl.request_alignment = 512;
    bs->bl.max_transfer = CHUNK_MAX_TRANSFER;
}

static const char *const chunk_strong_runtime_opts[] = {
    BLOCK_OPT_SIZE, "image-id", NULL
};

static BlockDriver bdrv_browser_chunk = {
    .format_name = "browser-chunk",
    .protocol_name = "browser-chunk",
    .instance_size = sizeof(BDRVBrowserChunkState),
    .bdrv_file_open = chunk_open,
    .bdrv_co_getlength = chunk_length,
    .bdrv_co_preadv = chunk_read,
    .bdrv_co_pwritev = chunk_write,
    .bdrv_co_flush_to_disk = chunk_flush,
    .bdrv_co_pdiscard = chunk_discard,
    .bdrv_refresh_limits = chunk_limits,
    .strong_runtime_opts = chunk_strong_runtime_opts,
};

static void bdrv_browser_chunk_init(void)
{
    bdrv_register(&bdrv_browser_chunk);
}
block_init(bdrv_browser_chunk_init);
#endif /* __EMSCRIPTEN__ */
