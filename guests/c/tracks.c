/* The tracks scene (tools/scenes/tracks.steps; docs/styling-pass-plan.md
 * Y5, Y6, Y7) with every field explicit: two tables whose title cell is a
 * `rounded` image beside a name over a caption, the name's `tint` bound to
 * the row's field, and each row `activatable` with `selected` bound to its
 * field, the app writing it from the `activated` occurrence (Y4). See
 * guests/rust/tracks.rs. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Guest-allocated ids; tools/check-c-ids.py holds the one id space. Each
 * table's template is LINE, NUMBER, CELL, ART, LINES, NAME, ARTIST, ALBUM. */
#define W_ROOT 1
#define W_ALBUM 2
#define N_A_LINE 3
#define N_A_NUMBER 4
#define N_A_CELL 5
#define N_A_ART 6
#define N_A_LINES 7
#define N_A_NAME 8
#define N_A_ARTIST 9
#define N_A_ALBUM 10
#define W_TRACKS 11
#define N_T_LINE 12
#define N_T_NUMBER 13
#define N_T_CELL 14
#define N_T_ART 15
#define N_T_LINES 16
#define N_T_NAME 17
#define N_T_ARTIST 18
#define N_T_ALBUM 19

#define C_ALBUM 1
#define C_PLAYLIST 2
#define F_NUMBER 0
#define F_TITLE 1
#define F_ARTIST 2
#define F_ALBUM 3
#define F_ART 4
#define F_TINT 5
#define F_SELECTED 6

#define PLAYLIST 60
#define PLAYING 3

static const char *const NAMES[3][3] = {
    {"Blue in Green", "Miles Davis", "Kind of Blue"},
    {"So What", "Miles Davis", "Kind of Blue"},
    {"Naima", "John Coltrane", "Giant Steps"},
};

static void submit(KayaTx *tx) {
    if (!kaya_tx_ok(tx)) {
        fprintf(stderr, "kaya: the tracks guest's transaction needs %zu bytes and was given %zu\n",
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

/* The create calls stay at the call site, where check-c-ids reads them. */
static void cells(KayaTx *tx, uint64_t base, const char *row_id) {
    uint64_t line = base, number = base + 1, cell = base + 2, art = base + 3, lines = base + 4,
             name = base + 5, artist = base + 6, album = base + 7;
    kaya_tx_bind_text_element(tx, number, 0, F_NUMBER);
    kaya_tx_add_child(tx, line, number);
    kaya_tx_bind_source_element(tx, art, 0, F_ART);
    kaya_tx_set_fit(tx, art, KAYA_FIT_COVER);
    kaya_tx_set_max_width(tx, art, 40.0);
    kaya_tx_set_max_height(tx, art, 40.0);
    kaya_tx_set_shape(tx, art, KAYA_SHAPE_ROUNDED);
    kaya_tx_set_a11y_id(tx, art, "art");
    kaya_tx_add_child(tx, cell, art);
    kaya_tx_bind_text_element(tx, name, 0, F_TITLE);
    kaya_tx_bind_tint_element(tx, name, 0, F_TINT);
    kaya_tx_set_a11y_id(tx, name, "name");
    kaya_tx_add_child(tx, lines, name);
    kaya_tx_bind_text_element(tx, artist, 0, F_ARTIST);
    kaya_tx_set_role(tx, artist, KAYA_ROLE_CAPTION);
    kaya_tx_add_child(tx, lines, artist);
    kaya_tx_add_child(tx, cell, lines);
    kaya_tx_add_child(tx, line, cell);
    kaya_tx_bind_text_element(tx, album, 0, F_ALBUM);
    kaya_tx_add_child(tx, line, album);
    kaya_tx_set_a11y_id(tx, line, row_id);
    kaya_tx_bind_selected_element(tx, line, 0, F_SELECTED);
    kaya_tx_set_activatable(tx, line, 1);
}

static void headers(KayaTx *tx, uint64_t table, const char *id) {
    KayaVal titles[] = {kaya_str("#"), kaya_str("Title"), kaya_str("Album")};
    kaya_tx_set_column_headers(tx, table, 0xFFFFFFFFu, 0, 3, 0, titles, 3);
    kaya_tx_set_a11y_id(tx, table, id);
    kaya_tx_add_child(tx, W_ROOT, table);
}

static void insert(KayaTx *tx, uint64_t collection, char prefix, int i, KayaVal art) {
    char key[8], number[8];
    snprintf(key, sizeof key, "%c%d", prefix, i + 1);
    snprintf(number, sizeof number, "%d", i + 1);
    const char *const *n = NAMES[i % 3];
    KayaVal fields[] = {kaya_str(number), kaya_str(n[0]), kaya_str(n[1]), kaya_str(n[2]), art,
                        kaya_i64(i + 1 == PLAYING ? KAYA_TINT_ACCENT : KAYA_TINT_NONE), kaya_bool(0)};
    kaya_tx_collection_insert(tx, collection, NULL, 0, kaya_str(key), 0, fields, 7);
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
    static uint8_t buf[16384];
    KayaTx tx = {buf, 0, sizeof buf};
    window_prop(&tx, KAYA_WPROP_TITLE, kaya_str("tracks"));
    window_prop(&tx, KAYA_WPROP_WIDTH, kaya_f64(720.0));
    window_prop(&tx, KAYA_WPROP_HEIGHT, kaya_f64(640.0));
    kaya_tx_create_widget(&tx, W_ROOT, KAYA_KIND_COLUMN);
    kaya_tx_set_spacing(&tx, W_ROOT, 12.0);
    uint32_t schema[] = {KAYA_VALUE_STR, KAYA_VALUE_STR, KAYA_VALUE_STR, KAYA_VALUE_STR, KAYA_VALUE_BLOB,
                         KAYA_VALUE_I64, KAYA_VALUE_BOOL};
    kaya_tx_create_collection(&tx, C_ALBUM, (KayaVariantSchema[]){{schema, 7}}, 1);
    kaya_tx_create_collection(&tx, C_PLAYLIST, (KayaVariantSchema[]){{schema, 7}}, 1);

    kaya_tx_create_for(&tx, W_ALBUM, C_ALBUM);
    kaya_tx_create_widget(&tx, N_A_LINE, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, N_A_NUMBER, KAYA_KIND_LABEL);
    kaya_tx_create_widget(&tx, N_A_CELL, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, N_A_ART, KAYA_KIND_IMAGE);
    kaya_tx_create_widget(&tx, N_A_LINES, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, N_A_NAME, KAYA_KIND_LABEL);
    kaya_tx_create_widget(&tx, N_A_ARTIST, KAYA_KIND_LABEL);
    kaya_tx_create_widget(&tx, N_A_ALBUM, KAYA_KIND_LABEL);
    cells(&tx, N_A_LINE, "a");
    kaya_tx_template_end(&tx);
    headers(&tx, W_ALBUM, "album");

    kaya_tx_create_for(&tx, W_TRACKS, C_PLAYLIST);
    kaya_tx_create_widget(&tx, N_T_LINE, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, N_T_NUMBER, KAYA_KIND_LABEL);
    kaya_tx_create_widget(&tx, N_T_CELL, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, N_T_ART, KAYA_KIND_IMAGE);
    kaya_tx_create_widget(&tx, N_T_LINES, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, N_T_NAME, KAYA_KIND_LABEL);
    kaya_tx_create_widget(&tx, N_T_ARTIST, KAYA_KIND_LABEL);
    kaya_tx_create_widget(&tx, N_T_ALBUM, KAYA_KIND_LABEL);
    cells(&tx, N_T_LINE, "t");
    kaya_tx_template_end(&tx);
    headers(&tx, W_TRACKS, "tracks");
    kaya_tx_set_grow(&tx, W_TRACKS, 1.0);
    kaya_tx_mount(&tx, 0, W_ROOT);

    KayaVal art = kaya_blob(kaya_blob_register(bytes, len));
    for (int i = 0; i < 3; i++)
        insert(&tx, C_ALBUM, 'a', i, art);
    for (int i = 0; i < PLAYLIST; i++)
        insert(&tx, C_PLAYLIST, 't', i, art);
    submit(&tx);
    kaya_asset_release(asset);
}

/* The app selects the row it was handed; kaya toggles nothing (Y4). */
static void select_in(KayaTx *tx, uint64_t collection, char prefix, int count, const KayaVal *picked) {
    for (int i = 0; i < count; i++) {
        char key[8];
        snprintf(key, sizeof key, "%c%d", prefix, i + 1);
        int on = picked->type == KAYA_VALUE_STR && picked->s_len == strlen(key) &&
                 memcmp(picked->s, key, picked->s_len) == 0;
        kaya_tx_collection_update_field(tx, collection, NULL, 0, kaya_str(key), F_SELECTED, 0, kaya_bool(on));
    }
}

static void on_row(const KayaVal *picked) {
    static uint8_t buf[8192];
    KayaTx tx = {buf, 0, sizeof buf};
    select_in(&tx, C_ALBUM, 'a', 3, picked);
    select_in(&tx, C_PLAYLIST, 't', PLAYLIST, picked);
    submit(&tx);
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
        if (kaya_parse_activated(rec, &id, keys, 2, &n_keys) && n_keys == 1 &&
            (id == N_A_LINE || id == N_T_LINE))
            on_row(&keys[0]);
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
