/* The layers scene (tools/scenes/layers.steps; docs/layering-plan.md LY13)
 * with every field explicit: the layers kind, each overlay's `place` after
 * its base, the container's inset, the fade form as the `overlay_fade` tint,
 * a veil hidden by a bound signal. See guests/rust/layers.rs. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* Guest-allocated ids; tools/check-c-ids.py holds the one id space. */
#define W_ROOT 1
#define W_PHOTOSTACK 2
#define W_PHOTO 3
#define W_BADGE 4
#define W_BADGE_TEXT 5
#define W_CAPTION 6
#define W_CAPTION_TEXT 7
#define W_SHARE 8
#define W_VEILSTACK 9
#define W_BASE 10
#define W_BUSY 11
#define W_BUSY_PANEL 12
#define W_BUSY_TEXT 13
#define W_SIDESTACK 14
#define W_SIDE 15
#define W_SIDEBADGE 16
#define W_SIDEBADGE_TEXT 17
#define W_FLATSTACK 18
#define W_SMALLPHOTO 19
#define W_FLAT 20
#define W_FLAT_TEXT 21
#define W_ANSWERED 22
#define W_HIDEVEIL 23

#define SIG_ANSWERED 1
#define SIG_VEILED 2

static void submit(KayaTx *tx) {
    if (!kaya_tx_ok(tx)) {
        fprintf(stderr, "kaya: the layers guest's transaction needs %zu bytes and was given %zu\n",
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

static uint64_t open_picture(const char *name, const uint8_t **bytes, uintptr_t *len) {
    uint64_t asset = kaya_asset_open((const uint8_t *)name, strlen(name));
    *bytes = asset == 0 ? NULL : kaya_asset_bytes(asset, len);
    if (*bytes == NULL) {
        fprintf(stderr, "kaya: %s did not open\n", name);
        _exit(1);
    }
    return asset;
}

/* A filled row holding one label, placed as an overlay. */
static void panel(KayaTx *tx, uint64_t row, uint64_t text_id, const char *text, int64_t tint, int64_t place,
                  const char *row_id, const char *text_a11y) {
    kaya_tx_create_widget(tx, row, KAYA_KIND_ROW);
    kaya_tx_create_widget(tx, text_id, KAYA_KIND_LABEL);
    kaya_tx_set_text(tx, text_id, text);
    if (text_a11y != NULL)
        kaya_tx_set_a11y_id(tx, text_id, text_a11y);
    kaya_tx_add_child(tx, row, text_id);
    kaya_tx_set_filled(tx, row, tint);
    if (place != 0)
        kaya_tx_set_place(tx, row, place);
    if (row_id != NULL)
        kaya_tx_set_a11y_id(tx, row, row_id);
}

static void build_scene(const uint8_t *cover, uintptr_t cover_len, const uint8_t *small, uintptr_t small_len) {
    uint8_t buf[8192];
    KayaTx tx = {buf, 0, sizeof buf};
    window_prop(&tx, KAYA_WPROP_TITLE, kaya_str("layers"));
    window_prop(&tx, KAYA_WPROP_WIDTH, kaya_f64(480.0));
    window_prop(&tx, KAYA_WPROP_HEIGHT, kaya_f64(860.0));
    kaya_tx_create_signal(&tx, SIG_ANSWERED, kaya_str("taps:"));
    kaya_tx_create_signal(&tx, SIG_VEILED, kaya_bool(0));

    kaya_tx_create_widget(&tx, W_ROOT, KAYA_KIND_COLUMN);
    kaya_tx_set_spacing(&tx, W_ROOT, 16.0);

    /* The cover: the base first, then the badge, the fade caption and the
     * button, each placed in the base's box at the container's inset. */
    kaya_tx_create_widget(&tx, W_PHOTOSTACK, KAYA_KIND_LAYERS);
    kaya_tx_add_child(&tx, W_ROOT, W_PHOTOSTACK);
    kaya_tx_create_widget(&tx, W_PHOTO, KAYA_KIND_IMAGE);
    kaya_tx_add_child(&tx, W_PHOTOSTACK, W_PHOTO);
    kaya_tx_set_source(&tx, W_PHOTO, kaya_blob_register(cover, cover_len));
    kaya_tx_set_max_width(&tx, W_PHOTO, 320.0);
    kaya_tx_set_a11y_label(&tx, W_PHOTO, "Kind of Blue cover");
    kaya_tx_set_a11y_id(&tx, W_PHOTO, "photo");
    panel(&tx, W_BADGE, W_BADGE_TEXT, "3", KAYA_TINT_ACCENT, KAYA_PLACE_TOP_TRAILING, "badge", "badge_text");
    kaya_tx_add_child(&tx, W_PHOTOSTACK, W_BADGE);
    panel(&tx, W_CAPTION, W_CAPTION_TEXT, "Kind of Blue", KAYA_TINT_OVERLAY_FADE, KAYA_PLACE_BOTTOM, "caption",
          "caption_text");
    kaya_tx_add_child(&tx, W_PHOTOSTACK, W_CAPTION);
    kaya_tx_create_widget(&tx, W_SHARE, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_SHARE, "Share");
    kaya_tx_add_child(&tx, W_PHOTOSTACK, W_SHARE);
    kaya_tx_set_place(&tx, W_SHARE, KAYA_PLACE_BOTTOM_TRAILING);
    kaya_tx_set_a11y_id(&tx, W_SHARE, "share");
    kaya_tx_set_inset(&tx, W_PHOTOSTACK, 8.0);
    kaya_tx_set_a11y_id(&tx, W_PHOTOSTACK, "photostack");

    /* The veil: an unfilled column spanning the base, its panel centred. */
    kaya_tx_create_widget(&tx, W_VEILSTACK, KAYA_KIND_LAYERS);
    kaya_tx_add_child(&tx, W_ROOT, W_VEILSTACK);
    kaya_tx_create_widget(&tx, W_BASE, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_BASE, "Press the base button here");
    kaya_tx_set_a11y_id(&tx, W_BASE, "base");
    kaya_tx_add_child(&tx, W_VEILSTACK, W_BASE);
    kaya_tx_create_widget(&tx, W_BUSY, KAYA_KIND_COLUMN);
    kaya_tx_add_child(&tx, W_VEILSTACK, W_BUSY);
    panel(&tx, W_BUSY_PANEL, W_BUSY_TEXT, "Busy", KAYA_TINT_OVERLAY, 0, NULL, NULL);
    kaya_tx_add_child(&tx, W_BUSY, W_BUSY_PANEL);
    kaya_tx_set_align(&tx, W_BUSY, KAYA_ALIGN_CENTER);
    kaya_tx_set_fill(&tx, W_BUSY, 1);
    kaya_tx_bind_hidden(&tx, W_BUSY, SIG_VEILED);
    kaya_tx_set_a11y_id(&tx, W_BUSY, "busy");
    kaya_tx_set_a11y_id(&tx, W_VEILSTACK, "veilstack");

    /* A button with a badge at its trailing end. */
    kaya_tx_create_widget(&tx, W_SIDESTACK, KAYA_KIND_LAYERS);
    kaya_tx_add_child(&tx, W_ROOT, W_SIDESTACK);
    kaya_tx_create_widget(&tx, W_SIDE, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_SIDE, "Open the inbox");
    kaya_tx_set_a11y_id(&tx, W_SIDE, "side");
    kaya_tx_add_child(&tx, W_SIDESTACK, W_SIDE);
    panel(&tx, W_SIDEBADGE, W_SIDEBADGE_TEXT, "5", KAYA_TINT_ACCENT, KAYA_PLACE_TRAILING, "sidebadge", NULL);
    kaya_tx_add_child(&tx, W_SIDESTACK, W_SIDEBADGE);
    kaya_tx_set_a11y_id(&tx, W_SIDESTACK, "sidestack");

    /* A smaller cover with the flat overlay panel. */
    kaya_tx_create_widget(&tx, W_FLATSTACK, KAYA_KIND_LAYERS);
    kaya_tx_add_child(&tx, W_ROOT, W_FLATSTACK);
    kaya_tx_create_widget(&tx, W_SMALLPHOTO, KAYA_KIND_IMAGE);
    kaya_tx_add_child(&tx, W_FLATSTACK, W_SMALLPHOTO);
    kaya_tx_set_source(&tx, W_SMALLPHOTO, kaya_blob_register(small, small_len));
    kaya_tx_set_max_width(&tx, W_SMALLPHOTO, 200.0);
    kaya_tx_set_a11y_label(&tx, W_SMALLPHOTO, "Small cover");
    kaya_tx_set_a11y_id(&tx, W_SMALLPHOTO, "smallphoto");
    panel(&tx, W_FLAT, W_FLAT_TEXT, "Flat panel", KAYA_TINT_OVERLAY, KAYA_PLACE_TOP_LEADING, "flat", "flat_text");
    kaya_tx_add_child(&tx, W_FLATSTACK, W_FLAT);
    kaya_tx_set_inset(&tx, W_FLATSTACK, 8.0);
    kaya_tx_set_a11y_id(&tx, W_FLATSTACK, "flatstack");

    kaya_tx_create_widget(&tx, W_ANSWERED, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_ANSWERED, SIG_ANSWERED);
    kaya_tx_set_a11y_id(&tx, W_ANSWERED, "answered");
    kaya_tx_add_child(&tx, W_ROOT, W_ANSWERED);
    kaya_tx_create_widget(&tx, W_HIDEVEIL, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_HIDEVEIL, "Hide the veil");
    kaya_tx_set_a11y_id(&tx, W_HIDEVEIL, "hideveil");
    kaya_tx_add_child(&tx, W_ROOT, W_HIDEVEIL);

    kaya_tx_mount(&tx, 0, W_ROOT);
    submit(&tx);
}

static void *app(void *arg) {
    (void)arg;
    const uint8_t *cover, *small;
    uintptr_t cover_len = 0, small_len = 0;
    uint64_t a = open_picture("covers/cover-600.jpg", &cover, &cover_len);
    uint64_t b = open_picture("covers/cover-320.jpg", &small, &small_len);
    build_scene(cover, cover_len, small, small_len);
    kaya_asset_release(a);
    kaya_asset_release(b);
    char log[256] = "taps:";
    const uint8_t *rec;
    for (;;) {
        size_t size = kaya_next_occurrence(&rec);
        if (size == 0)
            break; /* shutdown */
        if (size == KAYA_OCCURRENCE_WOKEN)
            continue;
        uint64_t id;
        KayaVal keys[2];
        uint32_t n_keys;
        if (!kaya_parse_click(rec, &id, keys, 2, &n_keys))
            continue;
        const char *word = id == W_SHARE ? "share" : id == W_BASE ? "base" : id == W_SIDE ? "side"
                                                     : id == W_HIDEVEIL ? "hide" : NULL;
        if (word == NULL || strlen(log) + strlen(word) + 2 > sizeof log)
            continue;
        strcat(log, " ");
        strcat(log, word);
        uint8_t buf[512];
        KayaTx tx = {buf, 0, sizeof buf};
        kaya_tx_write_signal(&tx, SIG_ANSWERED, kaya_str(log));
        if (id == W_HIDEVEIL)
            kaya_tx_write_signal(&tx, SIG_VEILED, kaya_bool(1));
        submit(&tx);
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
