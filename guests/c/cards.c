/* The cards scene (tools/scenes/cards.steps; docs/styling-pass-plan.md Y4)
 * with every field explicit: `activatable` on three filled cards and on a
 * stamped library row, `selected` bound to the row's field, and the
 * `activated` occurrence matched off the ring. See guests/rust/cards.rs. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Guest-allocated ids; tools/check-c-ids.py holds the one id space. */
#define W_ROOT 1
#define W_GRID 2
#define W_CARD1 3
#define W_CARD1_TITLE 4
#define W_CARD1_LINE 5
#define W_CARD2 6
#define W_CARD2_TITLE 7
#define W_CARD2_LINE 8
#define W_CARD3 9
#define W_CARD3_TITLE 10
#define W_CARD3_LINE 11
#define W_STATUS 12
#define W_LIBRARY 13
#define N_ITEM 14
#define N_ITEM_NAME 15

#define SIG_STATUS 1

#define C_LIBRARY 1
#define F_NAME 0
#define F_SELECTED 1

static const char *const CARD_IDS[3] = {"card1", "card2", "card3"};
static const char *const CARD_NAMES[3] = {"Daily Mix 1", "Daily Mix 2", "Discover Weekly"};
static const char *const LIB_KEYS[3] = {"p1", "p2", "p3"};
static const char *const LIB_NAMES[3] = {"Liked Songs", "Late Night Jazz", "Focus"};

static void submit(KayaTx *tx) {
    if (!kaya_tx_ok(tx)) {
        fprintf(stderr, "kaya: the cards guest's transaction needs %zu bytes and was given %zu\n",
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

static void card(KayaTx *tx, int i, uint64_t id, uint64_t title, uint64_t line) {
    kaya_tx_set_text(tx, title, CARD_NAMES[i]);
    kaya_tx_add_child(tx, id, title);
    kaya_tx_set_text(tx, line, "Made for you");
    kaya_tx_set_role(tx, line, KAYA_ROLE_CAPTION);
    kaya_tx_add_child(tx, id, line);
    kaya_tx_set_filled(tx, id, KAYA_TINT_NEUTRAL);
    kaya_tx_set_a11y_id(tx, id, CARD_IDS[i]);
    kaya_tx_set_activatable(tx, id, 1);
    kaya_tx_add_child(tx, W_GRID, id);
}

static void build_scene(void) {
    uint8_t buf[4096];
    KayaTx tx = {buf, 0, sizeof buf};
    window_prop(&tx, KAYA_WPROP_TITLE, kaya_str("cards"));
    window_prop(&tx, KAYA_WPROP_WIDTH, kaya_f64(520.0));
    window_prop(&tx, KAYA_WPROP_HEIGHT, kaya_f64(520.0));
    kaya_tx_create_signal(&tx, SIG_STATUS, kaya_str("opened: none"));

    kaya_tx_create_widget(&tx, W_ROOT, KAYA_KIND_COLUMN);
    kaya_tx_set_spacing(&tx, W_ROOT, 16.0);
    kaya_tx_create_widget(&tx, W_GRID, KAYA_KIND_GRID);
    kaya_tx_set_columns(&tx, W_GRID, 3.0);
    kaya_tx_set_spacing(&tx, W_GRID, 12.0);
    kaya_tx_create_widget(&tx, W_CARD1, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, W_CARD1_TITLE, KAYA_KIND_LABEL);
    kaya_tx_create_widget(&tx, W_CARD1_LINE, KAYA_KIND_LABEL);
    card(&tx, 0, W_CARD1, W_CARD1_TITLE, W_CARD1_LINE);
    kaya_tx_create_widget(&tx, W_CARD2, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, W_CARD2_TITLE, KAYA_KIND_LABEL);
    kaya_tx_create_widget(&tx, W_CARD2_LINE, KAYA_KIND_LABEL);
    card(&tx, 1, W_CARD2, W_CARD2_TITLE, W_CARD2_LINE);
    kaya_tx_create_widget(&tx, W_CARD3, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, W_CARD3_TITLE, KAYA_KIND_LABEL);
    kaya_tx_create_widget(&tx, W_CARD3_LINE, KAYA_KIND_LABEL);
    card(&tx, 2, W_CARD3, W_CARD3_TITLE, W_CARD3_LINE);
    kaya_tx_add_child(&tx, W_ROOT, W_GRID);

    kaya_tx_create_widget(&tx, W_STATUS, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_STATUS, SIG_STATUS);
    kaya_tx_set_a11y_id(&tx, W_STATUS, "status");
    kaya_tx_add_child(&tx, W_ROOT, W_STATUS);

    /* A playlist: its name and whether the app has selected it. */
    kaya_tx_create_collection(&tx, C_LIBRARY,
                              (KayaVariantSchema[]){{(uint32_t[]){KAYA_VALUE_STR, KAYA_VALUE_BOOL}, 2}},
                              1);
    kaya_tx_create_for(&tx, W_LIBRARY, C_LIBRARY);
    kaya_tx_create_widget(&tx, N_ITEM, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, N_ITEM_NAME, KAYA_KIND_LABEL);
    kaya_tx_bind_text_element(&tx, N_ITEM_NAME, 0, F_NAME);
    kaya_tx_add_child(&tx, N_ITEM, N_ITEM_NAME);
    kaya_tx_set_a11y_id(&tx, N_ITEM, "lib");
    kaya_tx_bind_selected_element(&tx, N_ITEM, 0, F_SELECTED);
    kaya_tx_set_activatable(&tx, N_ITEM, 1);
    kaya_tx_template_end(&tx);
    kaya_tx_add_child(&tx, W_ROOT, W_LIBRARY);
    kaya_tx_mount(&tx, 0, W_ROOT);
    for (int i = 0; i < 3; i++) {
        KayaVal fields[] = {kaya_str(LIB_NAMES[i]), kaya_bool(0)};
        kaya_tx_collection_insert(&tx, C_LIBRARY, NULL, 0, kaya_str(LIB_KEYS[i]), 0, fields, 2);
    }
    submit(&tx);
}

static void on_card(uint64_t id) {
    const uint64_t ids[3] = {W_CARD1, W_CARD2, W_CARD3};
    for (int i = 0; i < 3; i++) {
        if (ids[i] != id)
            continue;
        char status[64];
        snprintf(status, sizeof status, "opened: %s", CARD_NAMES[i]);
        uint8_t buf[256];
        KayaTx tx = {buf, 0, sizeof buf};
        kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str(status));
        submit(&tx);
    }
}

/* The app selects the row it was handed; kaya toggles nothing (Y4). */
static void on_row(const KayaVal *key) {
    uint8_t buf[512];
    KayaTx tx = {buf, 0, sizeof buf};
    for (int i = 0; i < 3; i++) {
        int picked = key->type == KAYA_VALUE_STR && key->s_len == strlen(LIB_KEYS[i]) &&
                     memcmp(key->s, LIB_KEYS[i], key->s_len) == 0;
        kaya_tx_collection_update_field(&tx, C_LIBRARY, NULL, 0, kaya_str(LIB_KEYS[i]), F_SELECTED, 0,
                                        kaya_bool(picked));
    }
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
        if (kaya_parse_activated(rec, &id, keys, 2, &n_keys)) {
            if (n_keys == 0)
                on_card(id);
            else if (n_keys == 1 && id == N_ITEM)
                on_row(&keys[0]);
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
