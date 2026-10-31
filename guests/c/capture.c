/* The capture at the floor (tools/scenes/capture.steps, capture_denied.steps;
 * docs/capture-plan.md): every capture record packed explicitly, the four
 * capture occurrences read through kaya_wire.h's flat parsers, and the
 * frames and samples handed to this code on kaya's capture thread. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* One id space (tools/check-c-ids.py). CREATION ORDER IS CONTRACT. */
#define SIG_DEVICES 1
#define SIG_PERMISSIONS 2
#define SIG_STATE 3
#define SIG_EVIDENCE 4
#define SIG_MISSING 5

#define W_COLUMN 1
#define W_DEVICES 2     /* label#0 */
#define W_PERMISSIONS 3 /* label#1 */
#define W_STATE 4       /* label#2 */
#define W_EVIDENCE 5    /* label#3 */
#define W_MISSING 6     /* label#4 */
#define W_BUTTONS 7
#define W_ASK 8         /* button#0 */
#define W_START 9       /* button#1 */
#define W_SWITCH 10     /* button#2 */
#define W_MUTE 11       /* button#3 */
#define W_CAMERA_OFF 12 /* button#4 */
#define W_STOP 13       /* button#5 */
#define W_OPEN_MISSING 14 /* button#6 */
#define W_WIDE_COVER 15 /* button#7 */
#define W_WIDE_CONTAIN 16 /* button#8 */
#define W_VIDEO 17      /* video#0 */

#define CALL 1
#define MISSING 2

static const char *const STATES[] = {"idle", "starting", "running", "interrupted", "failed"};
static const char *const FAILURES[] = {"none", "denied", "not_found", "in_use",
                                       "disconnected", "unsupported", "hardware_error", "timeout"};
static const char *const INTERRUPTIONS[] = {"none", "background", "another_app", "system_pressure"};
static const char *const KINDS[] = {"camera", "microphone"};
static const char *const PERMISSIONS[] = {"prompt", "granted", "denied"};
static const char *const FACINGS[] = {"unknown", "front", "back", "external"};

#define NAME(table, i) ((i) < sizeof(table) / sizeof(table[0]) ? (table)[i] : "?")

static uint32_t permission[2] = {KAYA_PERMISSION_PROMPT, KAYA_PERMISSION_PROMPT};

/* What this code saw on kaya's capture thread, posted by the app thread. */
static pthread_mutex_t seen_lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t seen_width, seen_height;
static size_t seen_chunk;
static int seen_dirty;

static void evidence(char *out, size_t cap) {
    char frames[48] = "app frames none", chunks[48] = "app chunks none";
    if (seen_width != 0)
        snprintf(frames, sizeof frames, "app frames %ux%u", seen_width, seen_height);
    if (seen_chunk != 0)
        snprintf(chunks, sizeof chunks, "app chunks of %zu", seen_chunk);
    snprintf(out, cap, "%s, %s", frames, chunks);
}

static void on_frame(void *ctx, const KayaCaptureFrame *f) {
    (void)ctx;
    int whole = f->y != NULL && f->uv != NULL && f->y_stride >= f->width &&
                f->uv_stride >= f->width;
    uint32_t w = whole ? f->width : 0, h = whole ? f->height : 0;
    pthread_mutex_lock(&seen_lock);
    int moved = w != seen_width || h != seen_height;
    if (moved) {
        seen_width = w;
        seen_height = h;
        seen_dirty = 1;
    }
    pthread_mutex_unlock(&seen_lock);
    if (moved)
        kaya_wake();
}

static void on_samples(void *ctx, const int16_t *samples, uintptr_t count, uint64_t at) {
    (void)ctx;
    (void)samples;
    (void)at;
    pthread_mutex_lock(&seen_lock);
    int first = seen_chunk == 0;
    if (first) {
        seen_chunk = count;
        seen_dirty = 1;
    }
    pthread_mutex_unlock(&seen_lock);
    if (first)
        kaya_wake();
}

static void window_prop(KayaTx *tx, uint32_t prop, KayaVal value) {
    size_t start = kaya_wire_begin(tx, KAYA_TX_SET_WINDOW_PROP);
    kaya_wire_u64(tx, 0);
    kaya_wire_u32(tx, prop);
    kaya_wire_u32(tx, KAYA_SOURCE_CONST);
    kaya_wire_value(tx, value);
    kaya_wire_end(tx, start);
}

static void label(KayaTx *tx, uint64_t id, uint64_t signal) {
    kaya_tx_create_widget(tx, id, KAYA_KIND_LABEL);
    kaya_tx_bind_text(tx, id, signal);
    kaya_tx_add_child(tx, W_COLUMN, id);
}

static void button(KayaTx *tx, uint64_t id, const char *text) {
    kaya_tx_create_widget(tx, id, KAYA_KIND_BUTTON);
    kaya_tx_set_text(tx, id, text);
    kaya_tx_add_child(tx, W_BUTTONS, id);
}

static void build_scene(void) {
    uint8_t buf[8192];
    KayaTx tx = {buf, 0, sizeof buf};
    char line[96];

    window_prop(&tx, KAYA_WPROP_TITLE, kaya_str("capture"));
    window_prop(&tx, KAYA_WPROP_WIDTH, kaya_f64(520.0));
    window_prop(&tx, KAYA_WPROP_HEIGHT, kaya_f64(640.0));

    evidence(line, sizeof line);
    kaya_tx_create_signal(&tx, SIG_DEVICES, kaya_str("devices"));
    kaya_tx_create_signal(&tx, SIG_PERMISSIONS, kaya_str("permissions"));
    kaya_tx_create_signal(&tx, SIG_STATE, kaya_str("idle"));
    kaya_tx_create_signal(&tx, SIG_EVIDENCE, kaya_str(line));
    kaya_tx_create_signal(&tx, SIG_MISSING, kaya_str("idle"));

    kaya_tx_create_capture(&tx, CALL);
    kaya_tx_set_capture_prop(&tx, CALL, KAYA_CPROP_CAMERA, kaya_str("kaya-synthetic-camera-1"));
    kaya_tx_set_capture_prop(&tx, CALL, KAYA_CPROP_MICROPHONE, kaya_str("kaya-synthetic-microphone-1"));
    kaya_tx_set_capture_prop(&tx, CALL, KAYA_CPROP_WIDTH, kaya_f64(600.0));
    kaya_tx_set_capture_prop(&tx, CALL, KAYA_CPROP_HEIGHT, kaya_f64(400.0));
    kaya_tx_set_capture_prop(&tx, CALL, KAYA_CPROP_FRAME_RATE, kaya_f64(30.0));
    kaya_tx_create_capture(&tx, MISSING);
    kaya_tx_set_capture_prop(&tx, MISSING, KAYA_CPROP_CAMERA, kaya_str("no-such-camera"));

    kaya_tx_create_widget(&tx, W_COLUMN, KAYA_KIND_COLUMN);
    label(&tx, W_DEVICES, SIG_DEVICES);
    label(&tx, W_PERMISSIONS, SIG_PERMISSIONS);
    label(&tx, W_STATE, SIG_STATE);
    label(&tx, W_EVIDENCE, SIG_EVIDENCE);
    label(&tx, W_MISSING, SIG_MISSING);
    kaya_tx_create_widget(&tx, W_BUTTONS, KAYA_KIND_ROW);
    kaya_tx_set_wrap(&tx, W_BUTTONS, 1);
    kaya_tx_add_child(&tx, W_COLUMN, W_BUTTONS);
    button(&tx, W_ASK, "Ask camera");
    button(&tx, W_START, "Start");
    button(&tx, W_SWITCH, "Switch");
    button(&tx, W_MUTE, "Mute");
    button(&tx, W_CAMERA_OFF, "Camera off");
    button(&tx, W_STOP, "Stop");
    button(&tx, W_OPEN_MISSING, "Open missing");
    button(&tx, W_WIDE_COVER, "Wide cover");
    button(&tx, W_WIDE_CONTAIN, "Wide contain");
    kaya_tx_create_widget(&tx, W_VIDEO, KAYA_KIND_VIDEO);
    kaya_tx_set_capture(&tx, W_VIDEO, CALL);
    kaya_tx_set_a11y_label(&tx, W_VIDEO, "Self view");
    kaya_tx_add_child(&tx, W_COLUMN, W_VIDEO);
    kaya_tx_mount(&tx, 0, W_COLUMN);
    kaya_tx_watch_capture_devices(&tx, 1);

    kaya_capture_on_frame(CALL, on_frame, NULL);
    kaya_capture_on_samples(CALL, on_samples, NULL);
    kaya_submit(tx.buf, tx.len);
}

/* label#2 and label#4, byte-frozen by tools/scenes/capture.steps. */
static void state_line(const KayaVal *vals, char *out, size_t cap) {
    uint32_t state = (uint32_t)vals[0].i;
    if (state == KAYA_CAPTURE_STATE_RUNNING)
        snprintf(out, cap, "running %lldx%lld@%lld", (long long)vals[3].i,
                 (long long)vals[4].i, (long long)vals[5].i);
    else if (state == KAYA_CAPTURE_STATE_FAILED)
        snprintf(out, cap, "failed %s", NAME(FAILURES, (size_t)vals[1].i));
    else if (state == KAYA_CAPTURE_STATE_INTERRUPTED)
        snprintf(out, cap, "interrupted %s", NAME(INTERRUPTIONS, (size_t)vals[2].i));
    else
        snprintf(out, cap, "%s", NAME(STATES, (size_t)state));
}

/* label#0: five values a device after the count (crates/kaya/src/spec.rs). */
static void device_line(const KayaVal *vals, uint32_t n, char *out, size_t cap) {
    size_t at = 0;
    out[0] = 0;
    for (uint32_t i = 1; i + 4 < n && at < cap; i += 5) {
        size_t kind = (size_t)vals[i + 2].i;
        at += (size_t)snprintf(out + at, cap - at, "%s%s %.*s", i == 1 ? "" : "; ",
                               NAME(KINDS, kind), (int)vals[i].s_len, vals[i].s);
        if (kind == KAYA_CAPTURE_KIND_CAMERA && at < cap)
            at += (size_t)snprintf(out + at, cap - at, " %s", NAME(FACINGS, (size_t)vals[i + 3].i));
        if (vals[i + 4].i && at < cap)
            at += (size_t)snprintf(out + at, cap - at, " preferred");
    }
}

static void *app(void *arg) {
    (void)arg;
    build_scene();
    const uint8_t *rec;
    for (;;) {
        size_t size = kaya_next_occurrence(&rec);
        if (size == 0)
            break; /* shutdown */
        uint8_t buf[1024];
        KayaTx tx = {buf, 0, sizeof buf};
        char line[512];
        uint64_t id;
        KayaVal keys[2], vals[64];
        uint32_t n_keys, n_vals;
        if (size == KAYA_OCCURRENCE_WOKEN) {
            pthread_mutex_lock(&seen_lock);
            int dirty = seen_dirty;
            seen_dirty = 0;
            evidence(line, sizeof line);
            pthread_mutex_unlock(&seen_lock);
            if (!dirty)
                continue;
            kaya_tx_write_signal(&tx, SIG_EVIDENCE, kaya_str(line));
        } else if (kaya_parse_click(rec, &id, keys, 2, &n_keys)) {
            if (n_keys != 0)
                continue;
            if (id == W_ASK) {
                kaya_tx_request_permission(&tx, KAYA_CAPTURE_KIND_CAMERA);
            } else if (id == W_START) {
                kaya_tx_capture_command(&tx, CALL, KAYA_CAPTURE_COMMAND_START);
            } else if (id == W_SWITCH) {
                kaya_tx_set_capture_prop(&tx, CALL, KAYA_CPROP_CAMERA, kaya_str("kaya-synthetic-camera-2"));
                kaya_tx_set_capture_prop(&tx, CALL, KAYA_CPROP_MICROPHONE, kaya_str("kaya-synthetic-microphone-2"));
                kaya_tx_set_capture_prop(&tx, CALL, KAYA_CPROP_WIDTH, kaya_f64(1280.0));
                kaya_tx_set_capture_prop(&tx, CALL, KAYA_CPROP_HEIGHT, kaya_f64(720.0));
                kaya_tx_set_capture_prop(&tx, CALL, KAYA_CPROP_FRAME_RATE, kaya_f64(15.0));
            } else if (id == W_MUTE) {
                kaya_tx_set_capture_prop(&tx, CALL, KAYA_CPROP_MUTED, kaya_bool(1));
            } else if (id == W_CAMERA_OFF) {
                kaya_tx_set_capture_prop(&tx, CALL, KAYA_CPROP_CAMERA, kaya_str(""));
            } else if (id == W_STOP) {
                kaya_tx_capture_command(&tx, CALL, KAYA_CAPTURE_COMMAND_STOP);
            } else if (id == W_OPEN_MISSING) {
                kaya_tx_capture_command(&tx, MISSING, KAYA_CAPTURE_COMMAND_START);
            } else if (id == W_WIDE_COVER) {
                kaya_tx_set_aspect(&tx, W_VIDEO, (int64_t)16 << 32 | 9);
                kaya_tx_set_fit(&tx, W_VIDEO, KAYA_FIT_COVER);
            } else if (id == W_WIDE_CONTAIN) {
                kaya_tx_set_fit(&tx, W_VIDEO, KAYA_FIT_CONTAIN);
            } else {
                continue;
            }
        } else if (kaya_parse_capture_changed(rec, &id, vals, 64, &n_vals)) {
            if (n_vals < 7)
                continue;
            state_line(vals, line, sizeof line);
            kaya_tx_write_signal(&tx, id == CALL ? SIG_STATE : SIG_MISSING, kaya_str(line));
        } else if (kaya_parse_capture_permission(rec, &id, vals, 64, &n_vals)) {
            if (n_vals < 2)
                continue;
            if ((uint64_t)vals[0].i < 2)
                permission[vals[0].i] = (uint32_t)vals[1].i;
            snprintf(line, sizeof line, "camera %s, microphone %s",
                     NAME(PERMISSIONS, (size_t)permission[0]),
                     NAME(PERMISSIONS, (size_t)permission[1]));
            kaya_tx_write_signal(&tx, SIG_PERMISSIONS, kaya_str(line));
        } else if (kaya_parse_capture_devices(rec, &id, vals, 64, &n_vals)) {
            device_line(vals, n_vals < 64 ? n_vals : 64, line, sizeof line);
            kaya_tx_write_signal(&tx, SIG_DEVICES, kaya_str(line));
        } else if (kaya_parse_capture_overrun(rec, &id, vals, 64, &n_vals)) {
            fprintf(stderr, "capture %llu is %lld ms behind\n", (unsigned long long)id,
                    n_vals ? (long long)vals[0].i : 0LL);
            continue;
        } else {
            continue;
        }
        if (kaya_tx_ok(&tx))
            kaya_submit(tx.buf, tx.len);
    }
    return NULL;
}

int main(void) {
    if (kaya_spec_hash() != KAYA_SPEC_HASH) {
        fprintf(stderr, "kaya: library/binding spec mismatch — rebuild both\n");
        return 1;
    }
    pthread_t app_thread;
    pthread_create(&app_thread, NULL, app, NULL);
    return kaya_run(); /* takes over the main thread until the app exits */
}
