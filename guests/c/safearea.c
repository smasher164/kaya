/* The safe-area scene (tools/scenes/safearea.steps; docs/safe-area-plan.md
 * A3, A8) on the floor: `bleed` (prop 61) on an image and on a canvas whose
 * drawing is a function of its size, answered at every draw_requested. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* Guest-allocated ids; tools/check-c-ids.py holds the one id space. */
#define W_ROOT 1
#define W_PICTURE 2
#define W_CAPTION 3
#define W_INSET 4
#define W_FULL 5
#define W_GROUND 6

#define SIG_CAPTION 1

static const char PHOTO[] = "images/photo.jpg";

/* Packed by hand: the generated setter closes the record BEFORE the value. */
static void window_prop(KayaTx *tx, uint32_t prop, KayaVal value) {
    size_t start = kaya_wire_begin(tx, KAYA_TX_SET_WINDOW_PROP);
    kaya_wire_u64(tx, 0);
    kaya_wire_u32(tx, prop);
    kaya_wire_u32(tx, KAYA_SOURCE_CONST);
    kaya_wire_value(tx, value);
    kaya_wire_end(tx, start);
}

static void draw_ground(KayaTx *tx, double w, double h) {
    KayaVal ops[] = {
        kaya_i64(KAYA_DRAW_MOVE_TO), kaya_f64(0.0), kaya_f64(0.0),
        kaya_i64(KAYA_DRAW_LINE_TO), kaya_f64(w),   kaya_f64(0.0),
        kaya_i64(KAYA_DRAW_LINE_TO), kaya_f64(w),   kaya_f64(h),
        kaya_i64(KAYA_DRAW_LINE_TO), kaya_f64(0.0), kaya_f64(h),
        kaya_i64(KAYA_DRAW_CLOSE),
        kaya_i64(KAYA_DRAW_FILL), kaya_i64(KAYA_PAINT_SERIES_FILL), kaya_i64(KAYA_FILL_NONZERO),
    };
    uint32_t n = sizeof ops / sizeof ops[0];
    kaya_tx_set_drawing(tx, W_GROUND, kaya_f64(w), kaya_f64(h), n, 0, ops, n);
}

static void build_scene(void) {
    uint8_t buf[8192];
    KayaTx tx = {buf, 0, sizeof buf};

    window_prop(&tx, KAYA_WPROP_TITLE, kaya_str("safearea"));
    window_prop(&tx, KAYA_WPROP_WIDTH, kaya_f64(420.0));
    window_prop(&tx, KAYA_WPROP_HEIGHT, kaya_f64(640.0));

    uint64_t photo = kaya_asset_open((const uint8_t *)PHOTO, strlen(PHOTO));
    if (photo == 0) {
        fprintf(stderr, "kaya: the asset %s did not open\n", PHOTO);
        _exit(1);
    }

    kaya_tx_create_signal(&tx, SIG_CAPTION, kaya_str("inset 16"));
    kaya_tx_create_widget(&tx, W_ROOT, KAYA_KIND_COLUMN);

    kaya_tx_create_widget(&tx, W_PICTURE, KAYA_KIND_IMAGE);
    kaya_tx_set_source(&tx, W_PICTURE, kaya_asset_blob(photo));
    kaya_tx_set_max_height(&tx, W_PICTURE, 160.0);
    kaya_tx_set_bleed(&tx, W_PICTURE, 1);
    kaya_tx_set_a11y_id(&tx, W_PICTURE, "picture");
    kaya_tx_set_a11y_label(&tx, W_PICTURE, "Photo");
    kaya_tx_add_child(&tx, W_ROOT, W_PICTURE);

    kaya_tx_create_widget(&tx, W_CAPTION, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_CAPTION, SIG_CAPTION);
    kaya_tx_set_a11y_id(&tx, W_CAPTION, "caption");
    kaya_tx_add_child(&tx, W_ROOT, W_CAPTION);

    kaya_tx_create_widget(&tx, W_INSET, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_INSET, "No inset");
    kaya_tx_set_a11y_id(&tx, W_INSET, "inset");
    kaya_tx_add_child(&tx, W_ROOT, W_INSET);

    kaya_tx_create_widget(&tx, W_FULL, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_FULL, "Fullscreen");
    kaya_tx_set_a11y_id(&tx, W_FULL, "full");
    kaya_tx_add_child(&tx, W_ROOT, W_FULL);

    kaya_tx_create_widget(&tx, W_GROUND, KAYA_KIND_CANVAS);
    kaya_tx_set_grow(&tx, W_GROUND, 1.0);
    kaya_tx_set_size_policy(&tx, W_GROUND, KAYA_SIZE_POLICY_REDRAW);
    kaya_tx_set_bleed(&tx, W_GROUND, 1);
    kaya_tx_set_a11y_id(&tx, W_GROUND, "ground");
    kaya_tx_set_a11y_label(&tx, W_GROUND, "Ground");
    kaya_tx_add_child(&tx, W_ROOT, W_GROUND);

    kaya_tx_mount(&tx, 0, W_ROOT); /* window 0: the default */

    kaya_submit(tx.buf, tx.len);
    kaya_asset_release(photo);
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
        KayaVal keys[2], vals[3];
        uint32_t n_keys, n_vals;
        uint8_t buf[1024];
        KayaTx tx = {buf, 0, sizeof buf};
        if (kaya_parse_draw_requested(rec, &id, keys, 2, &n_keys, vals, 3, &n_vals)) {
            if (id == W_GROUND && n_vals >= 2)
                draw_ground(&tx, vals[0].f, vals[1].f);
        } else if (kaya_parse_click(rec, &id, keys, 2, &n_keys)) {
            if (id == W_INSET) {
                window_prop(&tx, KAYA_WPROP_INSET, kaya_f64(0.0));
                kaya_tx_write_signal(&tx, SIG_CAPTION, kaya_str("inset 0"));
            } else if (id == W_FULL) {
                window_prop(&tx, KAYA_WPROP_FULLSCREEN, kaya_bool(1));
                kaya_tx_write_signal(&tx, SIG_CAPTION, kaya_str("fullscreen"));
            }
        }
        if (tx.len > 0)
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
