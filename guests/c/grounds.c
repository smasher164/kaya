/* The grounds scene (tools/scenes/grounds.steps; docs/styling-pass-plan.md
 * Y2, Y3) with every field explicit: the gradient ground as the `ground`
 * enum beside the `color` the core's kaya_image_dominant answers, the image
 * ground beside its `source`, the name on an `overlay` fill. See
 * guests/rust/grounds.rs. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* Guest-allocated ids; tools/check-c-ids.py holds the one id space. */
#define W_ROOT 1
#define W_HEADER 2
#define W_TITLE 3
#define W_ARTIST 4
#define W_HERO 5
#define W_SCRIM 6
#define W_NAME 7
#define W_PLAIN 8
#define W_PLAIN_TEXT 9

static void submit(KayaTx *tx) {
    if (!kaya_tx_ok(tx)) {
        fprintf(stderr, "kaya: the grounds guest's transaction needs %zu bytes and was given %zu\n",
                tx->len, tx->cap);
        _exit(1);
    }
    kaya_submit(tx->buf, tx->len);
}

/* Packed by hand: the generated setter closes the record BEFORE the value. */
static void window_prop(KayaTx *tx, uint32_t prop, KayaVal value) {
    size_t start = kaya_wire_begin(tx, KAYA_TX_SET_WINDOW_PROP);
    kaya_wire_u64(tx, 0);
    kaya_wire_u32(tx, prop);
    kaya_wire_u32(tx, KAYA_SOURCE_CONST);
    kaya_wire_value(tx, value);
    kaya_wire_end(tx, start);
}

static void build_scene(void) {
    static const char cover[] = "covers/cover-600.jpg";
    uint64_t asset = kaya_asset_open((const uint8_t *)cover, strlen(cover));
    uintptr_t len = 0;
    const uint8_t *art = asset == 0 ? NULL : kaya_asset_bytes(asset, &len);
    uint32_t rgb = 0;
    if (art == NULL || !kaya_image_dominant(art, len, &rgb)) {
        fprintf(stderr, "kaya: the cover did not open or decode\n");
        _exit(1);
    }

    uint8_t buf[4096];
    KayaTx tx = {buf, 0, sizeof buf};
    window_prop(&tx, KAYA_WPROP_TITLE, kaya_str("grounds"));
    window_prop(&tx, KAYA_WPROP_WIDTH, kaya_f64(480.0));
    window_prop(&tx, KAYA_WPROP_HEIGHT, kaya_f64(560.0));

    kaya_tx_create_widget(&tx, W_ROOT, KAYA_KIND_COLUMN);
    kaya_tx_set_spacing(&tx, W_ROOT, 12.0);

    /* The header: the dominant colour, clamped by the core, into the page. */
    kaya_tx_create_widget(&tx, W_HEADER, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, W_TITLE, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, W_TITLE, "Kind of Blue");
    kaya_tx_set_role(&tx, W_TITLE, KAYA_ROLE_HEADING);
    kaya_tx_set_a11y_id(&tx, W_TITLE, "title");
    kaya_tx_add_child(&tx, W_HEADER, W_TITLE);
    kaya_tx_create_widget(&tx, W_ARTIST, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, W_ARTIST, "Miles Davis · 1959");
    kaya_tx_set_role(&tx, W_ARTIST, KAYA_ROLE_CAPTION);
    kaya_tx_add_child(&tx, W_HEADER, W_ARTIST);
    kaya_tx_set_inset(&tx, W_HEADER, 24.0);
    kaya_tx_set_ground(&tx, W_HEADER, KAYA_GROUND_GRADIENT);
    kaya_tx_set_color(&tx, W_HEADER, (uint8_t)(rgb >> 16), (uint8_t)(rgb >> 8), (uint8_t)rgb, 0xFF);
    kaya_tx_set_a11y_id(&tx, W_HEADER, "header");
    kaya_tx_add_child(&tx, W_ROOT, W_HEADER);

    /* The hero: the picture as the ground, the name on the overlay panel. */
    kaya_tx_create_widget(&tx, W_HERO, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, W_SCRIM, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, W_NAME, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, W_NAME, "Miles Davis");
    kaya_tx_add_child(&tx, W_SCRIM, W_NAME);
    kaya_tx_set_filled(&tx, W_SCRIM, KAYA_TINT_OVERLAY);
    kaya_tx_set_a11y_id(&tx, W_SCRIM, "scrim");
    kaya_tx_add_child(&tx, W_HERO, W_SCRIM);
    kaya_tx_set_inset(&tx, W_HERO, 24.0);
    kaya_tx_set_ground(&tx, W_HERO, KAYA_GROUND_IMAGE);
    kaya_tx_set_source(&tx, W_HERO, kaya_blob_register(art, len));
    kaya_tx_set_a11y_id(&tx, W_HERO, "hero");
    kaya_tx_add_child(&tx, W_ROOT, W_HERO);

    kaya_tx_create_widget(&tx, W_PLAIN, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, W_PLAIN_TEXT, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, W_PLAIN_TEXT, "Plain");
    kaya_tx_add_child(&tx, W_PLAIN, W_PLAIN_TEXT);
    kaya_tx_set_inset(&tx, W_PLAIN, 24.0);
    kaya_tx_set_a11y_id(&tx, W_PLAIN, "plain");
    kaya_tx_add_child(&tx, W_ROOT, W_PLAIN);

    kaya_tx_mount(&tx, 0, W_ROOT);
    submit(&tx);
    kaya_asset_release(asset);
}

static void *app(void *arg) {
    (void)arg;
    build_scene();
    const uint8_t *rec;
    for (;;) {
        size_t size = kaya_next_occurrence(&rec);
        if (size == KAYA_OCCURRENCE_SHUTDOWN)
            break;
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
