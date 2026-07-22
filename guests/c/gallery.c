/* The gallery scene from C, on the function floor: a row with a
 * checkbox and its status label, and a row with a slider and its
 * volume label. Both controls own their state and report each change
 * as an occurrence; the app answers by writing the paired signal — the
 * same uncontrolled contract as the entry, with a bool and a double.
 *
 * Built and run by the Linux container suite with KAYA_SELFTEST=gallery. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>

/* Guest-allocated ids, counted from 1 per space. */
#define SIG_STATUS 1
#define SIG_VOLUME 2
#define SIG_POS 3
#define W_COLUMN 1
#define W_ROW 2
#define W_URGENT 3
#define W_STATUS 4
#define W_VOLUME_ROW 5
#define W_BAR 6
#define W_VOLUME 7
#define W_IMAGE_ROW 8
#define W_IMAGE_OK 9
#define W_IMAGE_BAD 10
#define W_QUARTER 11

/* A 2x2 RGB PNG (red/green over blue/white), 75 bytes: the first
 * binary asset, embedded as source per the include_str! doctrine —
 * scenes carry their inputs, no runtime file I/O. */
static const uint8_t TEST_PNG[75] = {
    137, 80,  78,  71,  13,  10,  26,  10,  0,   0,   0,   13,  73,
    72,  68,  82,  0,   0,   0,   2,   0,   0,   0,   2,   8,   2,
    0,   0,   0,   253, 212, 154, 115, 0,   0,   0,   18,  73,  68,
    65,  84,  120, 156, 99,  248, 207, 192, 192, 0,   194, 12,  255,
    129, 0,   0,   31,  238, 5,   251, 11,  217, 104, 139, 0,   0,
    0,   0,   73,  69,  78,  68,  174, 66,  96,  130};

static void build_scene(void) {
    uint8_t buf[1024];
    KayaTx tx = {buf, 0};

    kaya_tx_create_signal(&tx, SIG_STATUS, kaya_str("urgent: false"));
    kaya_tx_create_signal(&tx, SIG_VOLUME, kaya_str("volume: 50%"));
    kaya_tx_create_signal(&tx, SIG_POS, kaya_f64(0.5));
    kaya_tx_create_widget(&tx, W_COLUMN, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, W_ROW, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, W_URGENT, KAYA_KIND_CHECKBOX);
    kaya_tx_set_text(&tx, W_URGENT, "urgent");
    kaya_tx_create_widget(&tx, W_STATUS, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_STATUS, SIG_STATUS);
    kaya_tx_create_widget(&tx, W_VOLUME_ROW, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, W_BAR, KAYA_KIND_SLIDER);
    kaya_tx_set_min(&tx, W_BAR, 0.0);
    kaya_tx_set_max(&tx, W_BAR, 1.0);
    /* The slider's position binds a float signal — the programmatic
     * write path the quarter button drives below. */
    kaya_tx_bind_value(&tx, W_BAR, SIG_POS);
    kaya_tx_create_widget(&tx, W_VOLUME, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_VOLUME, SIG_VOLUME);
    kaya_tx_create_widget(&tx, W_QUARTER, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_QUARTER, "quarter");

    /* The content-buffer row: a valid 2x2 PNG decodes and reports its
     * size, and deliberately invalid bytes read 0x0 — decode failure
     * is the placeholder class, never a crash, on every backend. On
     * the function floor the blob channel is explicit: register the
     * bytes (one copy into core memory; the handle is consumed by the
     * next kaya_submit, and the guest's bytes are free to drop the
     * moment the call returns), then aim set_source at the widget. */
    static const uint8_t not_an_image[] = "not an image";
    uint64_t png_handle = kaya_blob_register(TEST_PNG, sizeof TEST_PNG);
    uint64_t bad_handle =
        kaya_blob_register(not_an_image, sizeof not_an_image - 1);
    kaya_tx_create_widget(&tx, W_IMAGE_ROW, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, W_IMAGE_OK, KAYA_KIND_IMAGE);
    kaya_tx_set_source(&tx, W_IMAGE_OK, png_handle);
    kaya_tx_create_widget(&tx, W_IMAGE_BAD, KAYA_KIND_IMAGE);
    kaya_tx_set_source(&tx, W_IMAGE_BAD, bad_handle);

    kaya_tx_add_child(&tx, W_ROW, W_URGENT);
    kaya_tx_add_child(&tx, W_ROW, W_STATUS);
    kaya_tx_add_child(&tx, W_COLUMN, W_ROW);
    kaya_tx_add_child(&tx, W_VOLUME_ROW, W_BAR);
    kaya_tx_add_child(&tx, W_VOLUME_ROW, W_VOLUME);
    kaya_tx_add_child(&tx, W_VOLUME_ROW, W_QUARTER);
    kaya_tx_add_child(&tx, W_COLUMN, W_VOLUME_ROW);
    kaya_tx_add_child(&tx, W_IMAGE_ROW, W_IMAGE_OK);
    kaya_tx_add_child(&tx, W_IMAGE_ROW, W_IMAGE_BAD);
    kaya_tx_add_child(&tx, W_COLUMN, W_IMAGE_ROW);
    kaya_tx_mount(&tx, 0, W_COLUMN); /* window 0: the default */

    kaya_submit(tx.buf, tx.len);
}

static void *app(void *arg) {
    (void)arg;
    build_scene();
    uint8_t rec[512];
    for (;;) {
        size_t size = kaya_next_occurrence(rec, sizeof rec);
        if (size == 0)
            break; /* shutdown */
        uint64_t id;
        KayaVal keys[2], checked, value;
        uint32_t n_keys;
        if (kaya_parse_toggled(rec, &id, keys, 2, &n_keys, &checked)) {
            if (id == W_URGENT && n_keys == 0) {
                uint8_t buf[256];
                KayaTx tx = {buf, 0};
                char status[32];
                snprintf(status, sizeof status, "urgent: %s",
                         checked.i ? "true" : "false");
                kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str(status));
                kaya_submit(tx.buf, tx.len);
            }
        } else if (kaya_parse_value_changed(rec, &id, keys, 2, &n_keys, &value)) {
            if (id == W_BAR && n_keys == 0) {
                uint8_t buf[256];
                KayaTx tx = {buf, 0};
                char volume[32];
                /* Integer percent, so every language's formatting
                 * agrees. */
                snprintf(volume, sizeof volume, "volume: %d%%",
                         (int)(value.f * 100.0 + 0.5));
                kaya_tx_write_signal(&tx, SIG_VOLUME, kaya_str(volume));
                kaya_submit(tx.buf, tx.len);
            }
        } else if (kaya_parse_click(rec, &id, keys, 2, &n_keys)) {
            if (id == W_QUARTER && n_keys == 0) {
                /* The programmatic write: fans out to the control and
                 * must NOT come back as a value_changed occurrence
                 * (property writes are configuration; only the user
                 * path and commands emit). */
                uint8_t buf[256];
                KayaTx tx = {buf, 0};
                kaya_tx_write_signal(&tx, SIG_POS, kaya_f64(0.25));
                kaya_submit(tx.buf, tx.len);
            }
        }
    }
    return NULL;
}

int main(void) {
    /* The stale-artifact guard: this guest compiled against one spec
     * revision; the loaded library must speak the same one. */
    if (kaya_spec_hash() != KAYA_SPEC_HASH) {
        fprintf(stderr, "kaya: library/binding spec mismatch — rebuild both\n");
        return 1;
    }
    pthread_t app_thread;
    pthread_create(&app_thread, NULL, app, NULL);
    return kaya_run(); /* takes over the main thread until the app exits */
}
