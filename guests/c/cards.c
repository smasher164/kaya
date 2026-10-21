/* The cards scene (tools/scenes/cards.steps; docs/styling-pass-plan.md Y4)
 * with every field explicit: `activatable` on three filled cards and on a
 * stamped library row, `selected` bound to the row's field, a stamped play
 * button whose `symbol` is the row's field, a fourth card added to the built
 * grid from a click (docs/media-player-plan.md M16), and the `activated` and
 * `button_clicked` occurrences matched off the ring. See guests/rust/cards.rs. */

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
#define W_CARD3_EXTRA 12
#define W_MORE 13
#define W_STATUS 14
#define W_LIBRARY 15
#define N_LINE 16
#define N_ITEM 17
#define N_ITEM_NAME 18
#define N_PLAY 19
#define W_CARD4 20
#define W_CARD4_TITLE 21
#define W_CARD4_LINE 22
/* A section hidden by a When and an empty For take no space (M16 (3)). */
#define W_HIDDEN 23
#define N_NEVER 24
#define W_EMPTY 25
#define N_EMPTY_ROW 26
#define N_EMPTY_NAME 27
#define W_END 28

#define SIG_STATUS 1
#define SIG_HIDDEN 2

#define C_LIBRARY 1
#define C_EMPTY 2
#define F_NAME 0
#define F_SELECTED 1
#define F_SYMBOL 2

static const char *const CARD_IDS[4] = {"card1", "card2", "card3", "card4"};
static const char *const CARD_NAMES[4] = {"Daily Mix 1", "Daily Mix 2", "Discover Weekly", "Release Radar"};
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
    /* The third card is taller, so the row's cards take its height (M16 (1)). */
    if (id == W_CARD3) {
        kaya_tx_set_text(tx, W_CARD3_EXTRA, "Fresh picks every Monday, from the artists you play the most and the ones they listen to");
        kaya_tx_set_max_lines(tx, W_CARD3_EXTRA, 2.0);
        kaya_tx_set_a11y_id(tx, W_CARD3_EXTRA, "blurb");
        kaya_tx_set_role(tx, W_CARD3_EXTRA, KAYA_ROLE_CAPTION);
        kaya_tx_add_child(tx, id, W_CARD3_EXTRA);
    }
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
    kaya_tx_set_columns(&tx, W_GRID, 0.0);
    kaya_tx_set_min_column_width(&tx, W_GRID, 140.0);
    kaya_tx_set_spacing(&tx, W_GRID, 12.0);
    kaya_tx_set_a11y_id(&tx, W_GRID, "cards");
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
    kaya_tx_create_widget(&tx, W_CARD3_EXTRA, KAYA_KIND_LABEL);
    card(&tx, 2, W_CARD3, W_CARD3_TITLE, W_CARD3_LINE);
    kaya_tx_add_child(&tx, W_ROOT, W_GRID);

    kaya_tx_create_widget(&tx, W_MORE, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_MORE, "More");
    kaya_tx_set_a11y_id(&tx, W_MORE, "more");
    kaya_tx_add_child(&tx, W_ROOT, W_MORE);

    kaya_tx_create_widget(&tx, W_STATUS, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_STATUS, SIG_STATUS);
    kaya_tx_set_a11y_id(&tx, W_STATUS, "status");
    kaya_tx_add_child(&tx, W_ROOT, W_STATUS);

    kaya_tx_create_signal(&tx, SIG_HIDDEN, kaya_bool(0));
    kaya_tx_create_when(&tx, W_HIDDEN, SIG_HIDDEN);
    kaya_tx_create_widget(&tx, N_NEVER, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, N_NEVER, "never shown");
    kaya_tx_template_end(&tx);
    kaya_tx_add_child(&tx, W_ROOT, W_HIDDEN);
    kaya_tx_create_collection(
        &tx, C_EMPTY,
        (KayaVariantSchema[]){{(uint32_t[]){KAYA_VALUE_STR, KAYA_VALUE_BOOL, KAYA_VALUE_I64}, 3}}, 1);
    kaya_tx_create_for(&tx, W_EMPTY, C_EMPTY);
    kaya_tx_create_widget(&tx, N_EMPTY_ROW, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, N_EMPTY_NAME, KAYA_KIND_LABEL);
    kaya_tx_bind_text_element(&tx, N_EMPTY_NAME, 0, F_NAME);
    kaya_tx_add_child(&tx, N_EMPTY_ROW, N_EMPTY_NAME);
    kaya_tx_template_end(&tx);
    kaya_tx_add_child(&tx, W_ROOT, W_EMPTY);
    kaya_tx_create_widget(&tx, W_END, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, W_END, "end");
    kaya_tx_set_a11y_id(&tx, W_END, "end");
    kaya_tx_add_child(&tx, W_ROOT, W_END);

    /* A playlist: its name, whether the app has selected it, and its play
     * button's symbol. */
    kaya_tx_create_collection(
        &tx, C_LIBRARY,
        (KayaVariantSchema[]){{(uint32_t[]){KAYA_VALUE_STR, KAYA_VALUE_BOOL, KAYA_VALUE_I64}, 3}}, 1);
    kaya_tx_create_for(&tx, W_LIBRARY, C_LIBRARY);
    kaya_tx_create_widget(&tx, N_LINE, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, N_ITEM, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, N_ITEM_NAME, KAYA_KIND_LABEL);
    kaya_tx_bind_text_element(&tx, N_ITEM_NAME, 0, F_NAME);
    kaya_tx_add_child(&tx, N_ITEM, N_ITEM_NAME);
    kaya_tx_set_a11y_id(&tx, N_ITEM, "lib");
    kaya_tx_bind_selected_element(&tx, N_ITEM, 0, F_SELECTED);
    kaya_tx_set_activatable(&tx, N_ITEM, 1);
    kaya_tx_add_child(&tx, N_LINE, N_ITEM);
    kaya_tx_create_widget(&tx, N_PLAY, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, N_PLAY, "Play");
    kaya_tx_bind_symbol_element(&tx, N_PLAY, 0, F_SYMBOL);
    kaya_tx_set_a11y_id(&tx, N_PLAY, "go");
    kaya_tx_add_child(&tx, N_LINE, N_PLAY);
    kaya_tx_template_end(&tx);
    kaya_tx_add_child(&tx, W_ROOT, W_LIBRARY);
    kaya_tx_mount(&tx, 0, W_ROOT);
    for (int i = 0; i < 3; i++) {
        KayaVal fields[] = {kaya_str(LIB_NAMES[i]), kaya_bool(0), kaya_i64(KAYA_SYMBOL_PLAY)};
        kaya_tx_collection_insert(&tx, C_LIBRARY, NULL, 0, kaya_str(LIB_KEYS[i]), 0, fields, 3);
    }
    submit(&tx);
}

static void on_card(uint64_t id) {
    const uint64_t ids[4] = {W_CARD1, W_CARD2, W_CARD3, W_CARD4};
    for (int i = 0; i < 4; i++) {
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

static int is_key(const KayaVal *key, int i) {
    return key->type == KAYA_VALUE_STR && key->s_len == strlen(LIB_KEYS[i]) &&
           memcmp(key->s, LIB_KEYS[i], key->s_len) == 0;
}

/* The app selects the row it was handed; kaya toggles nothing (Y4). */
static void on_row(const KayaVal *key) {
    uint8_t buf[512];
    KayaTx tx = {buf, 0, sizeof buf};
    for (int i = 0; i < 3; i++) {
        kaya_tx_collection_update_field(&tx, C_LIBRARY, NULL, 0, kaya_str(LIB_KEYS[i]), F_SELECTED, 0,
                                        kaya_bool(is_key(key, i)));
    }
    submit(&tx);
}

/* The played row's button shows pause, the others play (M16 (21)). */
static void on_play(const KayaVal *key) {
    uint8_t buf[512];
    KayaTx tx = {buf, 0, sizeof buf};
    for (int i = 0; i < 3; i++) {
        kaya_tx_collection_update_field(&tx, C_LIBRARY, NULL, 0, kaya_str(LIB_KEYS[i]), F_SYMBOL, 0,
                                        kaya_i64(is_key(key, i) ? KAYA_SYMBOL_PAUSE : KAYA_SYMBOL_PLAY));
    }
    submit(&tx);
}

/* A fourth card appended to the grid the build made (M16 (28)). */
static void on_more(void) {
    uint8_t buf[1024];
    KayaTx tx = {buf, 0, sizeof buf};
    kaya_tx_create_widget(&tx, W_CARD4, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, W_CARD4_TITLE, KAYA_KIND_LABEL);
    kaya_tx_create_widget(&tx, W_CARD4_LINE, KAYA_KIND_LABEL);
    card(&tx, 3, W_CARD4, W_CARD4_TITLE, W_CARD4_LINE);
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
        } else if (kaya_parse_click(rec, &id, keys, 2, &n_keys)) {
            if (n_keys == 0 && id == W_MORE)
                on_more();
            else if (n_keys == 1 && id == N_PLAY)
                on_play(&keys[0]);
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
