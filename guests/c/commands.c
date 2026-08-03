/* The standard-commands scene from C, at the explicit wire floor: menu
 * items hand-numbered in their OWN id space, every prop an explicit
 * set_menu_* record, and each chord in the CANONICAL wire spelling
 * ("primary+comma": lowercase, '+'-joined, primary/shift/alt order,
 * punctuation NAMED rather than spelled with the character) — the core
 * validates and REJECTS non-canonical spellings, so no canonicalizer
 * runs here. The role is likewise the canonical wire string.
 * Annotated semantics in guests/rust/commands.rs; the byte-frozen
 * contract in tools/scenes/commands.steps. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* Guest-allocated ids, counted from 1 per space. */
#define SIG_STATUS 1
#define SIG_DETAILS 2
#define SIG_SORT 3

/* Menu items: their OWN id space — never widget or node ids. */
#define M_FILE 1
#define M_RELOAD 2
#define M_SETTINGS 3
#define M_VIEW 4
#define M_DETAILS 5
#define M_SORT 6
#define M_NAME 7
#define M_DATE 8

#define W_COLUMN 1
#define W_STATUS 2 /* label#0 */

static int settings_count;

static void build_scene(void) {
    uint8_t buf[4096];
    KayaTx tx = {buf, 0};

    kaya_tx_create_signal(&tx, SIG_STATUS, kaya_str("ready"));
    kaya_tx_create_signal(&tx, SIG_DETAILS, kaya_bool(0));
    kaya_tx_create_signal(&tx, SIG_SORT, kaya_f64(0.0));

    {
        /* set_window_prop, raw wire: u64 window, u32 wprop, u32 source,
         * value — the floor writes the record by hand. */
        size_t start = kaya_wire_begin(&tx, KAYA_TX_SET_WINDOW_PROP);
        kaya_wire_u64(&tx, 0);
        kaya_wire_u32(&tx, KAYA_WPROP_TITLE);
        kaya_wire_u32(&tx, KAYA_SOURCE_CONST);
        kaya_wire_value(&tx, kaya_str("commands"));
        kaya_wire_end(&tx, start);
    }

    /* File: an ordinary command beside the settings command, which
     * carries both its punctuation chord and the role that tells macOS
     * where users look for it. The menu that declared it keeps a
     * visible item once the platform moves the other one. */
    kaya_tx_menu_item_create(&tx, M_FILE, KAYA_MENU_KIND_MENU);
    kaya_tx_set_menu_label(&tx, M_FILE, "File");
    kaya_tx_menu_item_create(&tx, M_RELOAD, KAYA_MENU_KIND_ACTION);
    kaya_tx_set_menu_label(&tx, M_RELOAD, "Reload");
    kaya_tx_menu_item_create(&tx, M_SETTINGS, KAYA_MENU_KIND_ACTION);
    kaya_tx_set_menu_label(&tx, M_SETTINGS, "Settings…");
    kaya_tx_set_menu_shortcut(&tx, M_SETTINGS, "primary+comma");
    kaya_tx_set_menu_role(&tx, M_SETTINGS, "settings");
    kaya_tx_menu_item_append(&tx, M_FILE, M_RELOAD);
    kaya_tx_menu_item_append(&tx, M_FILE, M_SETTINGS);
    kaya_tx_menubar_append(&tx, 0, M_FILE);

    /* View: a checkable command carrying its own key, and a nested
     * group whose options each answer their own chord. Option order IS
     * the index (Name = 0, Date = 1); value binds AFTER they exist. */
    kaya_tx_menu_item_create(&tx, M_VIEW, KAYA_MENU_KIND_MENU);
    kaya_tx_set_menu_label(&tx, M_VIEW, "View");
    kaya_tx_menu_item_create(&tx, M_DETAILS, KAYA_MENU_KIND_TOGGLE);
    kaya_tx_set_menu_label(&tx, M_DETAILS, "Details");
    kaya_tx_bind_menu_checked(&tx, M_DETAILS, SIG_DETAILS);
    kaya_tx_set_menu_shortcut(&tx, M_DETAILS, "primary+backslash");
    kaya_tx_menu_item_append(&tx, M_VIEW, M_DETAILS);
    kaya_tx_menu_item_create(&tx, M_SORT, KAYA_MENU_KIND_RADIO_GROUP);
    kaya_tx_set_menu_label(&tx, M_SORT, "Sort");
    kaya_tx_menu_item_create(&tx, M_NAME, KAYA_MENU_KIND_RADIO_OPTION);
    kaya_tx_set_menu_label(&tx, M_NAME, "Name");
    kaya_tx_set_menu_shortcut(&tx, M_NAME, "primary+1");
    kaya_tx_menu_item_create(&tx, M_DATE, KAYA_MENU_KIND_RADIO_OPTION);
    kaya_tx_set_menu_label(&tx, M_DATE, "Date");
    kaya_tx_set_menu_shortcut(&tx, M_DATE, "primary+2");
    kaya_tx_menu_item_append(&tx, M_SORT, M_NAME);
    kaya_tx_menu_item_append(&tx, M_SORT, M_DATE);
    kaya_tx_bind_menu_value(&tx, M_SORT, SIG_SORT);
    kaya_tx_menu_item_append(&tx, M_VIEW, M_SORT);
    kaya_tx_menubar_append(&tx, 0, M_VIEW);

    kaya_tx_create_widget(&tx, W_COLUMN, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, W_STATUS, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_STATUS, SIG_STATUS);
    kaya_tx_add_child(&tx, W_COLUMN, W_STATUS);
    kaya_tx_mount(&tx, 0, W_COLUMN);
    kaya_submit(tx.buf, tx.len);
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
        if (kaya_parse_menu_activated(rec, &id, keys, 2, &n_keys)) {
            if (n_keys == 0 && id == M_SETTINGS) {
                /* Fires twice on purpose: once by the chord, once by
                 * activating the item at its DECLARED path — which on
                 * macOS lives in the application menu by then. */
                char status[64];
                settings_count++;
                snprintf(status, sizeof status, "settings %d", settings_count);
                write_status(status);
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
    /* The stale-artifact guard: this guest compiled against one spec
     * revision; the loaded library must speak the same one. */
    if (kaya_spec_hash() != KAYA_SPEC_HASH) {
        fprintf(stderr, "kaya: library/binding spec mismatch — rebuild both\n");
        return 1;
    }
    pthread_t app_thread;
    pthread_create(&app_thread, NULL, app, NULL);
    return kaya_run(); /* takes over the main thread until the app exits */
}
