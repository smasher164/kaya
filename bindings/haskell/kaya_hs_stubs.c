/* Ordered cursor access for the Haskell direct-ring example. GHC's own
 * Addr# atomics are the wrong shape for this; DESIGN.md's milestone-0
 * note has the reasons. */

#include <stdatomic.h>
#include <stdint.h>

uint32_t kaya_hs_load_acquire_u32(const uint32_t *p)
{
    return atomic_load_explicit((const _Atomic uint32_t *)p,
                                memory_order_acquire);
}

void kaya_hs_store_release_u32(uint32_t *p, uint32_t v)
{
    atomic_store_explicit((_Atomic uint32_t *)p, v, memory_order_release);
}

/* The capture's two callbacks (docs/capture-plan.md §4), on kaya's capture
 * thread, the capture id as the context (never a pointer: the core calls a
 * sink outside its lock). hs_thread_done per call, never from a thread-exit
 * destructor: docs/traps.md, "OCaml 5 on macOS: a foreign thread cannot
 * unregister from a pthread key destructor". */

#include "HsFFI.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint32_t width;
    uint32_t height;
    const uint8_t *y;
    const uint8_t *uv;
    uint32_t y_stride;
    uint32_t uv_stride;
    uint64_t timestamp_ns;
    uint32_t rotation;
    uint32_t reserved;
} KayaHsCaptureFrame;

#define KAYA_HS_CAPTURE_CHUNK 480

extern void kaya_hs_capture_frame_in(void *ctx, const void *frame);
extern void kaya_hs_capture_samples_in(void *ctx, const int16_t *samples, uint64_t count,
                                       uint64_t timestamp_ns);

void kaya_hs_capture_frame(void *ctx, const KayaHsCaptureFrame *frame)
{
    kaya_hs_capture_frame_in(ctx, frame);
    hs_thread_done();
}

void kaya_hs_capture_samples(void *ctx, const int16_t *samples, uintptr_t count,
                             uint64_t timestamp_ns)
{
    kaya_hs_capture_samples_in(ctx, samples, (uint64_t)count, timestamp_ns);
    hs_thread_done();
}

/* guests/haskell/AbortCheck alone: call the two callbacks from a fresh
 * foreign thread, as kaya's capture thread does, over buffers the check
 * then reads back (a frame's planes 0x51/0x52, the samples 0..479)
 * and scribbles over once the call is done. */

struct kaya_hs_drive {
    uint64_t capture;
    uint32_t width, height;
    uint8_t *y, *uv;
    int16_t *samples;
};

static void *kaya_hs_drive_frame_thread(void *arg)
{
    struct kaya_hs_drive *d = arg;
    KayaHsCaptureFrame frame = {d->width, d->height, d->y, d->uv, d->width, d->width, 7, 0, 0};
    kaya_hs_capture_frame((void *)(uintptr_t)d->capture, &frame);
    return NULL;
}

static void *kaya_hs_drive_samples_thread(void *arg)
{
    struct kaya_hs_drive *d = arg;
    kaya_hs_capture_samples((void *)(uintptr_t)d->capture, d->samples, KAYA_HS_CAPTURE_CHUNK, 9);
    return NULL;
}

static int kaya_hs_drive(struct kaya_hs_drive *d, void *(*body)(void *))
{
    pthread_t thread;
    return pthread_create(&thread, NULL, body, d) || pthread_join(thread, NULL);
}

int kaya_hs_capture_drive_frame(uint64_t capture, uint32_t width, uint32_t height)
{
    struct kaya_hs_drive d = {capture, width, height, NULL, NULL, NULL};
    size_t y_len = (size_t)width * height, uv_len = (size_t)width * ((height + 1) / 2);
    d.y = malloc(y_len);
    d.uv = malloc(uv_len);
    memset(d.y, 0x51, y_len);
    memset(d.uv, 0x52, uv_len);
    int intact = !kaya_hs_drive(&d, kaya_hs_drive_frame_thread);
    for (size_t i = 0; intact && i < y_len; i++)
        intact = d.y[i] == 0x51;
    for (size_t i = 0; intact && i < uv_len; i++)
        intact = d.uv[i] == 0x52;
    memset(d.y, 0xEE, y_len);
    memset(d.uv, 0xEE, uv_len);
    free(d.y);
    free(d.uv);
    return intact;
}

int kaya_hs_capture_drive_samples(uint64_t capture)
{
    int16_t samples[KAYA_HS_CAPTURE_CHUNK];
    for (int i = 0; i < KAYA_HS_CAPTURE_CHUNK; i++)
        samples[i] = (int16_t)i;
    struct kaya_hs_drive d = {capture, 0, 0, NULL, NULL, samples};
    int intact = !kaya_hs_drive(&d, kaya_hs_drive_samples_thread);
    for (int i = 0; intact && i < KAYA_HS_CAPTURE_CHUNK; i++)
        intact = samples[i] == (int16_t)i;
    memset(samples, 0xEE, sizeof samples);
    return intact;
}
