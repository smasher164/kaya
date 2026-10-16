/* The shapes scene (tools/scenes/shapes.steps; docs/styling-pass-plan.md
 * Y6) with every field explicit: the `shape` enum on four live images and on
 * a stamped avatar that is round while it loads. See guests/rust/shapes.rs. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Guest-allocated ids; tools/check-c-ids.py holds the one id space. */
#define W_ROOT 1
#define W_ROW 2
#define W_RECT 3
#define W_ROUNDED 4
#define W_CIRCLE 5
#define W_WIDE 6
#define W_PEOPLE 7
#define N_PERSON 8
#define N_FACE 9
#define N_NAME 10

#define C_PEOPLE 1
#define F_NAME 0
#define F_FACE 1
#define F_PHASE 2

static void submit(KayaTx *tx) {
    if (!kaya_tx_ok(tx)) {
        fprintf(stderr, "kaya: the shapes guest's transaction needs %zu bytes and was given %zu\n",
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

static void image(KayaTx *tx, uint64_t id, uint64_t art, int64_t shape, int cover, const char *a11y_id) {
    kaya_tx_set_source(tx, id, art);
    kaya_tx_set_max_width(tx, id, 48.0);
    kaya_tx_set_max_height(tx, id, 48.0);
    if (cover)
        kaya_tx_set_fit(tx, id, KAYA_FIT_COVER);
    kaya_tx_set_shape(tx, id, shape);
    kaya_tx_set_a11y_id(tx, id, a11y_id);
    kaya_tx_add_child(tx, W_ROW, id);
}

static void build_scene(void) {
    size_t art_len, photo_len;
    uint8_t *art = load("covers/cover-600.jpg", &art_len);
    uint8_t *photo = load("images/photo.jpg", &photo_len);
    uint8_t buf[4096];
    KayaTx tx = {buf, 0, sizeof buf};
    window_prop(&tx, KAYA_WPROP_TITLE, kaya_str("shapes"));
    window_prop(&tx, KAYA_WPROP_WIDTH, kaya_f64(420.0));
    window_prop(&tx, KAYA_WPROP_HEIGHT, kaya_f64(360.0));

    kaya_tx_create_widget(&tx, W_ROOT, KAYA_KIND_COLUMN);
    kaya_tx_set_spacing(&tx, W_ROOT, 16.0);
    kaya_tx_create_widget(&tx, W_ROW, KAYA_KIND_ROW);
    kaya_tx_set_spacing(&tx, W_ROW, 16.0);
    uint64_t cover = kaya_blob_register(art, art_len);
    kaya_tx_create_widget(&tx, W_RECT, KAYA_KIND_IMAGE);
    image(&tx, W_RECT, cover, KAYA_SHAPE_RECT, 1, "rect");
    kaya_tx_create_widget(&tx, W_ROUNDED, KAYA_KIND_IMAGE);
    image(&tx, W_ROUNDED, cover, KAYA_SHAPE_ROUNDED, 1, "rounded");
    kaya_tx_create_widget(&tx, W_CIRCLE, KAYA_KIND_IMAGE);
    image(&tx, W_CIRCLE, cover, KAYA_SHAPE_CIRCLE, 1, "circle");
    /* No fit: the root covers a circle the app left unfitted. */
    kaya_tx_create_widget(&tx, W_WIDE, KAYA_KIND_IMAGE);
    image(&tx, W_WIDE, kaya_blob_register(photo, photo_len), KAYA_SHAPE_CIRCLE, 0, "wide");
    kaya_tx_add_child(&tx, W_ROOT, W_ROW);

    /* A person: a name, the face's bytes, the face's phase. */
    kaya_tx_create_collection(&tx, C_PEOPLE,
                              (KayaVariantSchema[]){{(uint32_t[]){KAYA_VALUE_STR, KAYA_VALUE_BLOB,
                                                                  KAYA_VALUE_I64},
                                                     3}},
                              1);
    kaya_tx_create_for(&tx, W_PEOPLE, C_PEOPLE);
    kaya_tx_create_widget(&tx, N_PERSON, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, N_FACE, KAYA_KIND_IMAGE);
    kaya_tx_bind_source_element(&tx, N_FACE, 0, F_FACE);
    kaya_tx_set_fit(&tx, N_FACE, KAYA_FIT_COVER);
    kaya_tx_set_max_width(&tx, N_FACE, 48.0);
    kaya_tx_set_max_height(&tx, N_FACE, 48.0);
    kaya_tx_bind_phase_element(&tx, N_FACE, 0, F_PHASE);
    kaya_tx_set_shape(&tx, N_FACE, KAYA_SHAPE_CIRCLE);
    kaya_tx_set_a11y_id(&tx, N_FACE, "avatar");
    kaya_tx_create_widget(&tx, N_NAME, KAYA_KIND_LABEL);
    kaya_tx_bind_text_element(&tx, N_NAME, 0, F_NAME);
    kaya_tx_add_child(&tx, N_PERSON, N_FACE);
    kaya_tx_add_child(&tx, N_PERSON, N_NAME);
    kaya_tx_template_end(&tx);
    kaya_tx_add_child(&tx, W_ROOT, W_PEOPLE);
    kaya_tx_mount(&tx, 0, W_ROOT);
    KayaVal ada[] = {kaya_str("Ada"), kaya_blob(kaya_blob_register(NULL, 0)), kaya_i64(KAYA_IMAGE_PHASE_LOADING)};
    kaya_tx_collection_insert(&tx, C_PEOPLE, NULL, 0, kaya_str("a1"), 0, ada, 3);
    submit(&tx);
    free(art);
    free(photo);
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
