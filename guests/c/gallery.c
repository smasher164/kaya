#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>

/* Guest-allocated ids; tools/check-c-ids.py holds the one id space. */
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
#define W_LEVEL_ROW 12
#define W_LEVEL_LABEL 13
#define W_LEVEL 14

/* A 2x2 RGB PNG (red/green over blue/white), embedded as source. */
static const uint8_t TEST_PNG[75] = {
    137, 80,  78,  71,  13,  10,  26,  10,  0,   0,   0,   13,  73,
    72,  68,  82,  0,   0,   0,   2,   0,   0,   0,   2,   8,   2,
    0,   0,   0,   253, 212, 154, 115, 0,   0,   0,   18,  73,  68,
    65,  84,  120, 156, 99,  248, 207, 192, 192, 0,   194, 12,  255,
    129, 0,   0,   31,  238, 5,   251, 11,  217, 104, 139, 0,   0,
    0,   0,   73,  69,  78,  68,  174, 66,  96,  130};

static void build_scene(void) {
    uint8_t buf[2048];
    KayaTx tx = {buf, 0, sizeof buf};

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
    kaya_tx_bind_value(&tx, W_BAR, SIG_POS);
    kaya_tx_create_widget(&tx, W_VOLUME, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_VOLUME, SIG_VOLUME);
    kaya_tx_create_widget(&tx, W_QUARTER, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_QUARTER, "quarter");

    /* A decode failure is the placeholder class, never a crash. A
     * REGISTERED BLOB IS CONSUMED BY THE NEXT kaya_submit. */
    static const uint8_t not_an_image[] = "not an image";
    uint64_t png_handle = kaya_blob_register(TEST_PNG, sizeof TEST_PNG);
    uint64_t bad_handle =
        kaya_blob_register(not_an_image, sizeof not_an_image - 1);
    kaya_tx_create_widget(&tx, W_IMAGE_ROW, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, W_IMAGE_OK, KAYA_KIND_IMAGE);
    kaya_tx_set_source(&tx, W_IMAGE_OK, png_handle);
    kaya_tx_create_widget(&tx, W_IMAGE_BAD, KAYA_KIND_IMAGE);
    kaya_tx_set_source(&tx, W_IMAGE_BAD, bad_handle);

    /* The labelled row: the control's accessibility name IS the label's
     * text, with no a11y label of its own. */
    kaya_tx_create_widget(&tx, W_LEVEL_ROW, KAYA_KIND_LABELED);
    kaya_tx_create_widget(&tx, W_LEVEL_LABEL, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, W_LEVEL_LABEL, "Level");
    kaya_tx_create_widget(&tx, W_LEVEL, KAYA_KIND_SLIDER);
    kaya_tx_set_min(&tx, W_LEVEL, 0.0);
    kaya_tx_set_max(&tx, W_LEVEL, 1.0);
    kaya_tx_set_value(&tx, W_LEVEL, 0.5);
    kaya_tx_set_a11y_id(&tx, W_LEVEL, "level");

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
    kaya_tx_add_child(&tx, W_LEVEL_ROW, W_LEVEL_LABEL);
    kaya_tx_add_child(&tx, W_LEVEL_ROW, W_LEVEL);
    kaya_tx_add_child(&tx, W_COLUMN, W_LEVEL_ROW);
    kaya_tx_mount(&tx, 0, W_COLUMN); /* window 0: the default */

    kaya_submit(tx.buf, tx.len);
}

static void *app(void *arg) {
    (void)arg;
    build_scene();
    const uint8_t *rec;
    for (;;) {
        size_t size = kaya_next_occurrence(&rec);
        if (size == 0)
            break; /* shutdown */
        if (size == KAYA_OCCURRENCE_WOKEN)
            continue; /* no record; rec is NULL */
        uint64_t id;
        KayaVal keys[2], checked, value;
        uint32_t n_keys;
        if (kaya_parse_toggled(rec, &id, keys, 2, &n_keys, &checked)) {
            if (id == W_URGENT && n_keys == 0) {
                uint8_t buf[256];
                KayaTx tx = {buf, 0, sizeof buf};
                char status[32];
                snprintf(status, sizeof status, "urgent: %s",
                         checked.i ? "true" : "false");
                kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str(status));
                kaya_submit(tx.buf, tx.len);
            }
        } else if (kaya_parse_value_changed(rec, &id, keys, 2, &n_keys, &value)) {
            if (id == W_BAR && n_keys == 0) {
                uint8_t buf[256];
                KayaTx tx = {buf, 0, sizeof buf};
                char volume[32];
                /* Integer percent: every language must format alike. */
                snprintf(volume, sizeof volume, "volume: %d%%",
                         (int)(value.f * 100.0 + 0.5));
                kaya_tx_write_signal(&tx, SIG_VOLUME, kaya_str(volume));
                kaya_submit(tx.buf, tx.len);
            }
        } else if (kaya_parse_click(rec, &id, keys, 2, &n_keys)) {
            if (id == W_QUARTER && n_keys == 0) {
                /* A programmatic write must NOT echo value_changed. */
                uint8_t buf[256];
                KayaTx tx = {buf, 0, sizeof buf};
                kaya_tx_write_signal(&tx, SIG_POS, kaya_f64(0.25));
                kaya_submit(tx.buf, tx.len);
            }
        }
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
