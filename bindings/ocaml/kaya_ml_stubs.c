/* Ordered cursor access for the OCaml direct-ring example: OCaml has no
 * ordered loads and stores on foreign memory (DESIGN.md's milestone-0
 * note). [@@noalloc] on the OCaml side makes these bare C calls. */

#include <caml/mlvalues.h>

#include <stdatomic.h>
#include <stdint.h>

CAMLprim value kaya_ml_load_acquire_u32(value addr)
{
    uint32_t v = atomic_load_explicit(
        (_Atomic uint32_t *)Nativeint_val(addr), memory_order_acquire);
    return Val_long(v);
}

CAMLprim value kaya_ml_store_release_u32(value addr, value v)
{
    atomic_store_explicit((_Atomic uint32_t *)Nativeint_val(addr),
                          (uint32_t)Long_val(v), memory_order_release);
    return Val_unit;
}

/* The capture's two callbacks (docs/capture-plan.md §4), on kaya's capture
 * thread. The context is the capture id, never a pointer: the core calls a
 * sink outside its lock, so a callback replaced or released mid-call must
 * leave nothing to dangle. */

#include <caml/alloc.h>
#include <caml/bigarray.h>
#include <caml/callback.h>
#include <caml/memory.h>
#include <caml/threads.h>

#include <pthread.h>
#include <string.h>

#include <stdlib.h>

/* kaya.h's KayaCaptureFrame and callback types, spelled here because dune
 * cannot reach crates/kaya/include; a drifted layout reads a wrong size,
 * which the capture scene's "app frames WxH" line refuses. */
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
} KayaCaptureFrame;
typedef void (*KayaCaptureFrameFn)(void *, const KayaCaptureFrame *);
typedef void (*KayaCaptureSamplesFn)(void *, const int16_t *, uintptr_t, uint64_t);
#define KAYA_CAPTURE_CHUNK 480

static _Atomic long kaya_ml_registered;
static _Atomic long kaya_ml_unregistered;

/* Per call, never once per thread: docs/traps.md, "OCaml 5 on macOS: a
 * foreign thread cannot unregister from a pthread key destructor". */
static int kaya_ml_enter(void)
{
    int registered = caml_c_thread_register();
    if (registered)
        atomic_fetch_add(&kaya_ml_registered, 1);
    caml_acquire_runtime_system();
    return registered;
}

static void kaya_ml_leave(int registered)
{
    caml_release_runtime_system();
    if (registered && caml_c_thread_unregister())
        atomic_fetch_add(&kaya_ml_unregistered, 1);
}

static void kaya_ml_frame_call(uint64_t capture, const KayaCaptureFrame *f)
{
    CAMLparam0();
    CAMLlocalN(args, 9);
    const value *handler = caml_named_value("kaya_capture_frame");
    if (handler != NULL) {
        size_t y_len = (size_t)f->y_stride * f->height;
        size_t uv_len = (size_t)f->uv_stride * ((f->height + 1) / 2);
        args[0] = caml_copy_int64((int64_t)capture);
        args[1] = Val_long(f->width);
        args[2] = Val_long(f->height);
        args[3] = caml_alloc_initialized_string(y_len, (const char *)f->y);
        args[4] = caml_alloc_initialized_string(uv_len, (const char *)f->uv);
        args[5] = Val_long(f->y_stride);
        args[6] = Val_long(f->uv_stride);
        args[7] = caml_copy_int64((int64_t)f->timestamp_ns);
        args[8] = Val_long(f->rotation);
        caml_callbackN_exn(*handler, 9, args);
    }
    CAMLreturn0;
}

static void kaya_ml_samples_call(uint64_t capture, const int16_t *samples, uintptr_t count,
                                 uint64_t timestamp_ns)
{
    CAMLparam0();
    CAMLlocal3(id, chunk, at);
    const value *handler = caml_named_value("kaya_capture_samples");
    if (handler != NULL) {
        id = caml_copy_int64((int64_t)capture);
        chunk = caml_ba_alloc_dims(CAML_BA_SINT16 | CAML_BA_C_LAYOUT, 1, NULL, (intnat)count);
        memcpy(Caml_ba_data_val(chunk), samples, count * sizeof(int16_t));
        at = caml_copy_int64((int64_t)timestamp_ns);
        caml_callback3_exn(*handler, id, chunk, at);
    }
    CAMLreturn0;
}

static void kaya_ml_capture_frame(void *ctx, const KayaCaptureFrame *frame)
{
    int registered = kaya_ml_enter();
    kaya_ml_frame_call((uint64_t)(uintptr_t)ctx, frame);
    kaya_ml_leave(registered);
}

static void kaya_ml_capture_samples(void *ctx, const int16_t *samples, uintptr_t count,
                                    uint64_t timestamp_ns)
{
    int registered = kaya_ml_enter();
    kaya_ml_samples_call((uint64_t)(uintptr_t)ctx, samples, count, timestamp_ns);
    kaya_ml_leave(registered);
}

CAMLprim value kaya_ml_capture_frame_fn(value unit)
{
    (void)unit;
    KayaCaptureFrameFn fn = kaya_ml_capture_frame;
    return caml_copy_nativeint((intnat)fn);
}

CAMLprim value kaya_ml_capture_samples_fn(value unit)
{
    (void)unit;
    KayaCaptureSamplesFn fn = kaya_ml_capture_samples;
    return caml_copy_nativeint((intnat)fn);
}

/* bindings/ocaml/checks alone: call the two callbacks from a fresh
 * foreign thread, as kaya's capture thread does, over buffers the check
 * then reads back (a frame's planes 0x51/0x52, the samples 0..count-1)
 * and scribbles over once the call is done. */

struct kaya_ml_drive {
    uint64_t capture;
    uint32_t width, height;
    uint8_t *y, *uv;
    int16_t *samples;
};

static void *kaya_ml_drive_frame_thread(void *arg)
{
    struct kaya_ml_drive *d = arg;
    KayaCaptureFrame frame = {d->width, d->height, d->y, d->uv, d->width, d->width, 7, 0, 0};
    kaya_ml_capture_frame((void *)(uintptr_t)d->capture, &frame);
    return NULL;
}

static void *kaya_ml_drive_samples_thread(void *arg)
{
    struct kaya_ml_drive *d = arg;
    kaya_ml_capture_samples((void *)(uintptr_t)d->capture, d->samples, KAYA_CAPTURE_CHUNK, 9);
    return NULL;
}

static int kaya_ml_drive(struct kaya_ml_drive *d, void *(*body)(void *))
{
    pthread_t thread;
    caml_release_runtime_system();
    int failed = pthread_create(&thread, NULL, body, d) || pthread_join(thread, NULL);
    caml_acquire_runtime_system();
    return failed;
}

/* Answers whether kaya's own planes came back as they were sent. */
CAMLprim value kaya_ml_capture_drive_frame(value capture, value width, value height)
{
    struct kaya_ml_drive d = {(uint64_t)Int64_val(capture), (uint32_t)Long_val(width),
                              (uint32_t)Long_val(height), NULL, NULL, NULL};
    size_t y_len = (size_t)d.width * d.height, uv_len = (size_t)d.width * ((d.height + 1) / 2);
    d.y = malloc(y_len);
    d.uv = malloc(uv_len);
    memset(d.y, 0x51, y_len);
    memset(d.uv, 0x52, uv_len);
    int failed = kaya_ml_drive(&d, kaya_ml_drive_frame_thread);
    int intact = !failed;
    for (size_t i = 0; intact && i < y_len; i++)
        intact = d.y[i] == 0x51;
    for (size_t i = 0; intact && i < uv_len; i++)
        intact = d.uv[i] == 0x52;
    memset(d.y, 0xEE, y_len);
    memset(d.uv, 0xEE, uv_len);
    free(d.y);
    free(d.uv);
    return Val_bool(intact);
}

CAMLprim value kaya_ml_capture_drive_samples(value capture)
{
    int16_t samples[KAYA_CAPTURE_CHUNK];
    for (int i = 0; i < KAYA_CAPTURE_CHUNK; i++)
        samples[i] = (int16_t)i;
    struct kaya_ml_drive d = {(uint64_t)Int64_val(capture), 0, 0, NULL, NULL, samples};
    int failed = kaya_ml_drive(&d, kaya_ml_drive_samples_thread);
    int intact = !failed;
    for (int i = 0; intact && i < KAYA_CAPTURE_CHUNK; i++)
        intact = samples[i] == (int16_t)i;
    memset(samples, 0xEE, sizeof samples);
    return Val_bool(intact);
}

CAMLprim value kaya_ml_capture_thread_counts(value unit)
{
    (void)unit;
    value pair = caml_alloc_tuple(2);
    Store_field(pair, 0, Val_long(atomic_load(&kaya_ml_registered)));
    Store_field(pair, 1, Val_long(atomic_load(&kaya_ml_unregistered)));
    return pair;
}
