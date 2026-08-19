/* The menus scene from C, at the explicit wire floor. The shortcut is
 * in the CANONICAL wire spelling ("primary+s": lowercase, '+'-joined,
 * primary/shift/alt order) — the core REJECTS non-canonical spellings.
 * Semantics: guests/rust/menus.rs. Contract: tools/scenes/menus.steps. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* Guest-allocated ids, counted from 1 per space. */
#define SIG_STATUS 1
#define SIG_CAN_EXPORT 2
#define SIG_DETAILS 3
#define SIG_SORT 4
#define SIG_TARGET 5

/* Menu items: their OWN id space — never widget or node ids. */
#define M_FILE 1
#define M_SAVE 2
#define M_EXPORT 3
#define M_SHARE 4
#define M_VIEW 5
#define M_DETAILS 6
#define M_SORT 7
#define M_NAME 8
#define M_DATE 9
#define M_REMOVE 10
#define M_RENAME 11
#define M_PUBLISH 12
#define M_TOOLS 13
#define M_INSPECT 14

#define W_COLUMN 1
#define W_STATUS 2 /* label#0 */
#define W_ENABLE 3 /* button#0 */
#define W_RESET 4  /* button#1 */
#define W_EXTEND 5 /* button#2 */
#define W_TARGET 6 /* label#1 */
#define W_FOR_GROUPS 7
#define C_GROUPS 1
#define C_ITEMS 2
#define N_GROUP_COL 1
#define N_ITEMS_FOR 2
#define N_ROW 3 /* label#2 once g2/a stamps */

static void build_scene(void) {
    uint8_t buf[4096];
    KayaTx tx = {buf, 0};

    kaya_tx_create_signal(&tx, SIG_STATUS, kaya_str("ready"));
    kaya_tx_create_signal(&tx, SIG_CAN_EXPORT, kaya_bool(0));
    kaya_tx_create_signal(&tx, SIG_DETAILS, kaya_bool(0));
    kaya_tx_create_signal(&tx, SIG_SORT, kaya_f64(0.0));

    {
        /* Packed by hand: the generated kaya_tx_set_window_prop closes
         * the record BEFORE the value. */
        size_t start = kaya_wire_begin(&tx, KAYA_TX_SET_WINDOW_PROP);
        kaya_wire_u64(&tx, 0);
        kaya_wire_u32(&tx, KAYA_WPROP_TITLE);
        kaya_wire_u32(&tx, KAYA_SOURCE_CONST);
        kaya_wire_value(&tx, kaya_str("menus"));
        kaya_wire_end(&tx, start);
    }
    kaya_tx_menu_item_create(&tx, M_FILE, KAYA_MENU_KIND_MENU);
    kaya_tx_set_menu_label(&tx, M_FILE, "File");
    kaya_tx_bind_menu_enabled(&tx, M_FILE, SIG_CAN_EXPORT);
    kaya_tx_menu_item_create(&tx, M_SAVE, KAYA_MENU_KIND_ACTION);
    kaya_tx_set_menu_label(&tx, M_SAVE, "Save");
    kaya_tx_set_menu_symbol(&tx, M_SAVE, KAYA_SYMBOL_DONE);
    kaya_tx_set_menu_shortcut(&tx, M_SAVE, "primary+s");
    kaya_tx_menu_item_create(&tx, M_EXPORT, KAYA_MENU_KIND_ACTION);
    kaya_tx_set_menu_label(&tx, M_EXPORT, "Export");
    kaya_tx_set_menu_symbol(&tx, M_EXPORT, KAYA_SYMBOL_FORWARD);
    kaya_tx_bind_menu_enabled(&tx, M_EXPORT, SIG_CAN_EXPORT);
    kaya_tx_menu_item_create(&tx, M_SHARE, KAYA_MENU_KIND_ACTION);
    kaya_tx_set_menu_label(&tx, M_SHARE, "Share");
    kaya_tx_set_menu_primary(&tx, M_SHARE, 1);
    kaya_tx_menu_item_append(&tx, M_FILE, M_SAVE);
    kaya_tx_menu_item_append(&tx, M_FILE, M_EXPORT);
    kaya_tx_menu_item_append(&tx, M_FILE, M_SHARE);
    kaya_tx_menubar_append(&tx, 0, M_FILE);

    kaya_tx_menu_item_create(&tx, M_VIEW, KAYA_MENU_KIND_MENU);
    kaya_tx_set_menu_label(&tx, M_VIEW, "View");
    kaya_tx_menu_item_create(&tx, M_DETAILS, KAYA_MENU_KIND_TOGGLE);
    kaya_tx_set_menu_label(&tx, M_DETAILS, "Details");
    kaya_tx_set_menu_symbol(&tx, M_DETAILS, KAYA_SYMBOL_INFO);
    kaya_tx_bind_menu_checked(&tx, M_DETAILS, SIG_DETAILS);
    kaya_tx_menu_item_append(&tx, M_VIEW, M_DETAILS);
    kaya_tx_menubar_append(&tx, 0, M_VIEW);

    /* Option order IS the index (Name = 0, Date = 1); value binds AFTER
     * the options exist. */
    kaya_tx_menu_item_create(&tx, M_SORT, KAYA_MENU_KIND_RADIO_GROUP);
    kaya_tx_set_menu_label(&tx, M_SORT, "Sort");
    kaya_tx_menu_item_create(&tx, M_NAME, KAYA_MENU_KIND_RADIO_OPTION);
    kaya_tx_set_menu_label(&tx, M_NAME, "Name");
    kaya_tx_menu_item_create(&tx, M_DATE, KAYA_MENU_KIND_RADIO_OPTION);
    kaya_tx_set_menu_label(&tx, M_DATE, "Date");
    kaya_tx_menu_item_append(&tx, M_SORT, M_NAME);
    kaya_tx_menu_item_append(&tx, M_SORT, M_DATE);
    kaya_tx_bind_menu_value(&tx, M_SORT, SIG_SORT);
    kaya_tx_menubar_append(&tx, 0, M_SORT);

    /* The context catalog is built LIVE; only the attachment happens
     * inside the template below. */
    kaya_tx_menu_item_create(&tx, M_REMOVE, KAYA_MENU_KIND_ACTION);
    kaya_tx_set_menu_label(&tx, M_REMOVE, "Remove");
    kaya_tx_set_menu_symbol(&tx, M_REMOVE, KAYA_SYMBOL_DELETE);

    kaya_tx_create_widget(&tx, W_COLUMN, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, W_STATUS, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_STATUS, SIG_STATUS);
    kaya_tx_create_widget(&tx, W_ENABLE, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_ENABLE, "enable export");
    kaya_tx_create_widget(&tx, W_RESET, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_RESET, "reset menu state");
    kaya_tx_create_widget(&tx, W_EXTEND, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_EXTEND, "extend menus");

    kaya_tx_create_signal(&tx, SIG_TARGET, kaya_str("rename target"));
    kaya_tx_create_widget(&tx, W_TARGET, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_TARGET, SIG_TARGET);
    kaya_tx_menu_item_create(&tx, M_RENAME, KAYA_MENU_KIND_ACTION);
    kaya_tx_set_menu_label(&tx, M_RENAME, "Rename");
    kaya_tx_set_menu_symbol(&tx, M_RENAME, KAYA_SYMBOL_EDIT);
    kaya_tx_context_attach(&tx, W_TARGET, M_RENAME);

    /* Two-level For: activation names BOTH keys, group then item. */
    kaya_tx_create_collection(&tx, C_GROUPS,
                              (KayaVariantSchema[]){{(uint32_t[]){KAYA_VALUE_STR}, 1}}, 1);
    kaya_tx_create_for(&tx, W_FOR_GROUPS, C_GROUPS);
    kaya_tx_create_widget(&tx, N_GROUP_COL, KAYA_KIND_COLUMN);
    kaya_tx_create_collection(&tx, C_ITEMS,
                              (KayaVariantSchema[]){{(uint32_t[]){KAYA_VALUE_STR}, 1}}, 1);
    kaya_tx_create_for(&tx, N_ITEMS_FOR, C_ITEMS);
    kaya_tx_create_widget(&tx, N_ROW, KAYA_KIND_LABEL);
    kaya_tx_bind_text_element(&tx, N_ROW, 0, 0);
    kaya_tx_context_attach_node(&tx, N_ROW, M_REMOVE);
    kaya_tx_template_end(&tx);
    kaya_tx_add_child(&tx, N_GROUP_COL, N_ITEMS_FOR);
    kaya_tx_template_end(&tx);

    kaya_tx_add_child(&tx, W_COLUMN, W_STATUS);
    kaya_tx_add_child(&tx, W_COLUMN, W_ENABLE);
    kaya_tx_add_child(&tx, W_COLUMN, W_RESET);
    kaya_tx_add_child(&tx, W_COLUMN, W_EXTEND);
    kaya_tx_add_child(&tx, W_COLUMN, W_TARGET);
    kaya_tx_add_child(&tx, W_COLUMN, W_FOR_GROUPS);
    kaya_tx_mount(&tx, 0, W_COLUMN);
    kaya_submit(tx.buf, tx.len);

    /* Seeded AFTER mount, so the stamp path attaches the shared catalog
     * and the copy's keys. */
    {
        uint8_t seed_buf[512];
        KayaTx seed = {seed_buf, 0};
        KayaVal g2 = kaya_str("g2");
        kaya_tx_collection_insert(&seed, C_GROUPS, 0, 0, kaya_str("g2"), 0,
                                  (KayaVal[]){kaya_str("Home")}, 1);
        kaya_tx_collection_insert(&seed, C_ITEMS, &g2, 1, kaya_str("a"), 0,
                                  (KayaVal[]){kaya_str("water plants")}, 1);
        kaya_submit(seed.buf, seed.len);
    }
}

static void write_status(const char *status) {
    uint8_t buf[256];
    KayaTx tx = {buf, 0};
    kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str(status));
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
        KayaVal keys[2];
        KayaVal payload;
        uint32_t n_keys;
        if (kaya_parse_click(rec, &id, keys, 2, &n_keys) && n_keys == 0) {
            if (id == W_ENABLE) {
                uint8_t buf[256];
                KayaTx tx = {buf, 0};
                kaya_tx_write_signal(&tx, SIG_CAN_EXPORT, kaya_bool(1));
                kaya_submit(tx.buf, tx.len);
            } else if (id == W_RESET) {
                /* The checked/value writes reset the backend's user-state
                 * mirror and echo no occurrence. */
                uint8_t buf[512];
                KayaTx tx = {buf, 0};
                kaya_tx_write_signal(&tx, SIG_DETAILS, kaya_bool(0));
                kaya_tx_write_signal(&tx, SIG_SORT, kaya_f64(0.0));
                kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str("ready"));
                kaya_submit(tx.buf, tx.len);
            } else if (id == W_EXTEND) {
                /* Append-only: rename the RETAINED File, move the
                 * promotion hint to Publish, grow the bar by Tools. */
                uint8_t buf[1024];
                KayaTx tx = {buf, 0};
                kaya_tx_set_menu_primary(&tx, M_SHARE, 0);
                kaya_tx_set_menu_label(&tx, M_FILE, "Document");
                kaya_tx_menu_item_create(&tx, M_PUBLISH, KAYA_MENU_KIND_ACTION);
                kaya_tx_set_menu_label(&tx, M_PUBLISH, "Publish");
                kaya_tx_set_menu_symbol(&tx, M_PUBLISH, KAYA_SYMBOL_COPY);
                kaya_tx_set_menu_primary(&tx, M_PUBLISH, 1);
                kaya_tx_menu_item_append(&tx, M_FILE, M_PUBLISH);
                kaya_tx_menu_item_create(&tx, M_TOOLS, KAYA_MENU_KIND_MENU);
                kaya_tx_set_menu_label(&tx, M_TOOLS, "Tools");
                kaya_tx_menu_item_create(&tx, M_INSPECT, KAYA_MENU_KIND_ACTION);
                kaya_tx_set_menu_label(&tx, M_INSPECT, "Inspect");
                kaya_tx_set_menu_symbol(&tx, M_INSPECT, KAYA_SYMBOL_SEARCH);
                kaya_tx_menu_item_append(&tx, M_TOOLS, M_INSPECT);
                kaya_tx_menubar_append(&tx, 0, M_TOOLS);
                kaya_submit(tx.buf, tx.len);
            }
        } else if (kaya_parse_menu_activated(rec, &id, keys, 2, &n_keys)) {
            if (n_keys == 0 && id == M_SAVE) {
                write_status("saved");
            } else if (n_keys == 0 && (id == M_SHARE || id == M_PUBLISH)) {
                write_status("shared");
            } else if (n_keys == 0 && id == M_RENAME) {
                write_status("renamed");
            } else if (n_keys == 2 && id == M_REMOVE) {
                /* The keys ARE the noun: both levels straight into the
                 * instance address. */
                uint8_t buf[512];
                KayaTx tx = {buf, 0};
                kaya_tx_collection_remove(&tx, C_ITEMS, &keys[0], 1, keys[1]);
                char status[160];
                snprintf(status, sizeof status, "removed %.*s/%.*s",
                         keys[0].s_len, keys[0].s, keys[1].s_len, keys[1].s);
                kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str(status));
                kaya_submit(tx.buf, tx.len);
            }
        } else if (kaya_parse_menu_toggled(rec, &id, keys, 2, &n_keys, &payload)) {
            if (id == M_DETAILS) {
                write_status(payload.i ? "details on" : "details off");
            }
        } else if (kaya_parse_menu_value_changed(rec, &id, keys, 2, &n_keys, &payload)) {
            if (id == M_SORT) {
                write_status(payload.f == 1.0 ? "sorted date" : "sorted name");
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
