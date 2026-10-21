/* The dock scene (tools/scenes/dock.steps; docs/styling-pass-plan.md Y8)
 * with every field explicit: attach_dock names the window's dock, a mount
 * fills it, and a When over a Bool signal empties its root while nothing
 * plays. See guests/rust/dock.rs. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Guest-allocated ids; tools/check-c-ids.py holds the one id space. Surface
 * ids are their own namespace: the dock is surface 40. */
#define W_DOCK_ROOT 1
#define W_WHEN 2
#define N_BAR 3
#define N_ART 4
#define N_LINES 5
#define N_SONG 6
#define N_ARTIST 7
#define N_PROGRESS 8
#define N_PAUSE 9
#define W_ROOT 10
#define W_LIBRARY 11
#define W_STOP 12
#define W_PLAY 13

#define DOCK 40
#define SIG_PLAYING 1
#define PLAYER 1

static void submit(KayaTx *tx) {
    if (!kaya_tx_ok(tx)) {
        fprintf(stderr, "kaya: the dock guest's transaction needs %zu bytes and was given %zu\n",
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

/* An asset's bytes, copied out before the handle goes. */
static uint8_t *load(const char *name, size_t *len) {
    uint64_t asset = kaya_asset_open((const uint8_t *)name, strlen(name));
    uintptr_t n = 0;
    const uint8_t *bytes = asset == 0 ? NULL : kaya_asset_bytes(asset, &n);
    if (bytes == NULL) {
        fprintf(stderr, "kaya: the asset %s did not open\n", name);
        _exit(1);
    }
    uint8_t *copy = malloc(n);
    memcpy(copy, bytes, n);
    kaya_asset_release(asset);
    *len = n;
    return copy;
}

static void build_scene(void) {
    static const char cover[] = "covers/cover-600.jpg";
    uint64_t asset = kaya_asset_open((const uint8_t *)cover, strlen(cover));
    uintptr_t len = 0;
    const uint8_t *bytes = asset == 0 ? NULL : kaya_asset_bytes(asset, &len);
    if (bytes == NULL) {
        fprintf(stderr, "kaya: the asset %s did not open\n", cover);
        _exit(1);
    }
    uint8_t buf[4096];
    KayaTx tx = {buf, 0, sizeof buf};
    kaya_tx_create_signal(&tx, SIG_PLAYING, kaya_bool(1));
    window_prop(&tx, KAYA_WPROP_TITLE, kaya_str("dock"));
    window_prop(&tx, KAYA_WPROP_WIDTH, kaya_f64(720.0));
    window_prop(&tx, KAYA_WPROP_HEIGHT, kaya_f64(480.0));
    kaya_tx_create_player(&tx, PLAYER);
    kaya_tx_attach_dock(&tx, 0, DOCK);
    kaya_tx_set_dock_player(&tx, DOCK, PLAYER);

    kaya_tx_create_widget(&tx, W_DOCK_ROOT, KAYA_KIND_COLUMN);
    kaya_tx_create_when(&tx, W_WHEN, SIG_PLAYING);
    kaya_tx_create_widget(&tx, N_BAR, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, N_ART, KAYA_KIND_IMAGE);
    kaya_tx_set_source(&tx, N_ART, kaya_blob_register(bytes, len));
    kaya_tx_set_fit(&tx, N_ART, KAYA_FIT_COVER);
    kaya_tx_set_max_width(&tx, N_ART, 40.0);
    kaya_tx_set_max_height(&tx, N_ART, 40.0);
    kaya_tx_set_shape(&tx, N_ART, KAYA_SHAPE_ROUNDED);
    kaya_tx_add_child(&tx, N_BAR, N_ART);
    kaya_tx_create_widget(&tx, N_LINES, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, N_SONG, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, N_SONG, "Blue in Green");
    kaya_tx_add_child(&tx, N_LINES, N_SONG);
    kaya_tx_create_widget(&tx, N_ARTIST, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, N_ARTIST, "Miles Davis");
    kaya_tx_set_role(&tx, N_ARTIST, KAYA_ROLE_CAPTION);
    kaya_tx_add_child(&tx, N_LINES, N_ARTIST);
    kaya_tx_add_child(&tx, N_BAR, N_LINES);
    kaya_tx_create_widget(&tx, N_PROGRESS, KAYA_KIND_SLIDER);
    kaya_tx_set_min(&tx, N_PROGRESS, 0.0);
    kaya_tx_set_max(&tx, N_PROGRESS, 1.0);
    kaya_tx_set_value(&tx, N_PROGRESS, 0.4);
    kaya_tx_set_a11y_id(&tx, N_PROGRESS, "progress");
    kaya_tx_add_child(&tx, N_BAR, N_PROGRESS);
    kaya_tx_create_widget(&tx, N_PAUSE, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, N_PAUSE, "Pause");
    kaya_tx_set_a11y_id(&tx, N_PAUSE, "pause");
    kaya_tx_add_child(&tx, N_BAR, N_PAUSE);
    kaya_tx_set_a11y_id(&tx, N_BAR, "bar");
    kaya_tx_template_end(&tx);
    kaya_tx_add_child(&tx, W_DOCK_ROOT, W_WHEN);
    kaya_tx_mount(&tx, DOCK, W_DOCK_ROOT);

    kaya_tx_create_widget(&tx, W_ROOT, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, W_LIBRARY, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, W_LIBRARY, "Library");
    kaya_tx_add_child(&tx, W_ROOT, W_LIBRARY);
    kaya_tx_create_widget(&tx, W_STOP, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_STOP, "stop");
    kaya_tx_set_a11y_id(&tx, W_STOP, "stop");
    kaya_tx_add_child(&tx, W_ROOT, W_STOP);
    kaya_tx_create_widget(&tx, W_PLAY, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_PLAY, "play");
    kaya_tx_set_a11y_id(&tx, W_PLAY, "play");
    kaya_tx_add_child(&tx, W_ROOT, W_PLAY);
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
        if (size == KAYA_OCCURRENCE_WOKEN)
            continue;
        uint64_t id;
        KayaVal keys[2];
        uint32_t n_keys;
        if (kaya_parse_click(rec, &id, keys, 2, &n_keys) && n_keys == 0 && (id == W_STOP || id == W_PLAY)) {
            uint8_t small[128];
            KayaTx tx = {small, 0, sizeof small};
            kaya_tx_write_signal(&tx, SIG_PLAYING, kaya_bool(id == W_PLAY));
            submit(&tx);
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
