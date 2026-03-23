/*
 * Wasmtime custom platform implementation for Redox OS.
 *
 * Redox is Unix-like and has mmap/mprotect/munmap via relibc, but lacks
 * ucontext_t, sigaltstack, and siginfo_t.si_addr() needed by Wasmtime's
 * unix signal handler. This file provides the wasmtime_* platform symbols
 * using Redox's POSIX-compatible mmap and pthread TLS.
 *
 * Compiled and linked into the wasmtime binary during cross-compilation.
 */

#include <errno.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/mman.h>
#include <unistd.h>

/* ── Virtual memory ────────────────────────────────────────────────── */

#define WASMTIME_PROT_READ  (1 << 0)
#define WASMTIME_PROT_WRITE (1 << 1)
#define WASMTIME_PROT_EXEC  (1 << 2)

static int to_mmap_prot(uint32_t prot_flags) {
    int flags = 0;
    if (prot_flags & WASMTIME_PROT_READ)  flags |= PROT_READ;
    if (prot_flags & WASMTIME_PROT_WRITE) flags |= PROT_WRITE;
    if (prot_flags & WASMTIME_PROT_EXEC)  flags |= PROT_EXEC;
    return flags;
}

int wasmtime_mmap_new(uintptr_t size, uint32_t prot_flags, uint8_t **ret) {
    void *p = mmap(NULL, size, to_mmap_prot(prot_flags),
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED)
        return errno;
    *ret = (uint8_t *)p;
    return 0;
}

int wasmtime_mmap_remap(uint8_t *addr, uintptr_t size, uint32_t prot_flags) {
    void *p = mmap(addr, size, to_mmap_prot(prot_flags),
                   MAP_FIXED | MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED)
        return errno;
    return 0;
}

int wasmtime_munmap(uint8_t *ptr, uintptr_t size) {
    if (munmap(ptr, size) != 0)
        return errno;
    return 0;
}

int wasmtime_mprotect(uint8_t *ptr, uintptr_t size, uint32_t prot_flags) {
    if (mprotect(ptr, size, to_mmap_prot(prot_flags)) != 0)
        return errno;
    return 0;
}

uintptr_t wasmtime_page_size(void) {
    return (uintptr_t)sysconf(_SC_PAGESIZE);
}

/* ── Memory images (not supported, return NULL) ────────────────────── */

struct wasmtime_memory_image;

int wasmtime_memory_image_new(const uint8_t *ptr, uintptr_t len,
                              struct wasmtime_memory_image **ret) {
    (void)ptr;
    (void)len;
    *ret = NULL;
    return 0;
}

int wasmtime_memory_image_map_at(struct wasmtime_memory_image *image,
                                 uint8_t *addr, uintptr_t len) {
    (void)image;
    (void)addr;
    (void)len;
    return ENOTSUP;
}

void wasmtime_memory_image_free(struct wasmtime_memory_image *image) {
    (void)image;
}

/* ── Thread-local storage ──────────────────────────────────────────── */

static pthread_key_t tls_key;
static pthread_once_t tls_once = PTHREAD_ONCE_INIT;

static void make_tls_key(void) {
    pthread_key_create(&tls_key, NULL);
}

uint8_t *wasmtime_tls_get(void) {
    pthread_once(&tls_once, make_tls_key);
    return (uint8_t *)pthread_getspecific(tls_key);
}

void wasmtime_tls_set(uint8_t *val) {
    pthread_once(&tls_once, make_tls_key);
    pthread_setspecific(tls_key, val);
}
