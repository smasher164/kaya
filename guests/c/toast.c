/* The toast scene at the floor (tools/scenes/toast.steps; docs/toast-plan.md
 * T15): every field of kaya_tx_show_toast explicit, the answer read off the
 * ring as toast_result. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* One id space (tools/check-c-ids.py). CREATION ORDER IS CONTRACT. */
#define SIG_LAST 1
#define SIG_COUNT 2
#define SIG_UNDONE 3
#define SIG_ROWS 4

#define W_COLUMN 1
#define W_LAST 2    /* label#0 */
#define W_COUNT 3   /* label#1 */
#define W_UNDONE 4  /* label#2 */
#define W_ROWS 5    /* label#3 */
#define W_SHOW 6    /* button#0 */
#define W_FIRST 7   /* button#1 */
#define W_SECOND 8  /* button#2 */
#define W_DELETE 9  /* button#3 */
#define W_HOLD 10   /* button#4 */
#define W_DISMISS 11 /* button#5 */
#define W_FOR_ITEMS 12

#define C_ITEMS 1

#define N_ROW 13
#define N_TITLE 14

#define F_TITLE 0

#define MAX_ITEMS 8
#define MAX_TITLE 64
static int64_t item_keys[MAX_ITEMS];
static char item_titles[MAX_ITEMS][MAX_TITLE];
static unsigned n_items = 0;

static void build_scene(void) {
    uint8_t buf[4096];
    KayaTx tx = {buf, 0, sizeof buf};

    {
        /* Packed by hand: the generated setter closes the record first. */
        size_t start = kaya_wire_begin(&tx, KAYA_TX_SET_WINDOW_PROP);
        kaya_wire_u64(&tx, 0);
        kaya_wire_u32(&tx, KAYA_WPROP_TITLE);
        kaya_wire_u32(&tx, KAYA_SOURCE_CONST);
        kaya_wire_value(&tx, kaya_str("toast"));
        kaya_wire_end(&tx, start);
    }
    kaya_tx_menu_item_create(&tx, 1, KAYA_MENU_KIND_MENU);
    kaya_tx_set_menu_label(&tx, 1, "Edit");
    kaya_tx_menu_item_create(&tx, 2, KAYA_MENU_KIND_ACTION);
    kaya_tx_set_menu_label(&tx, 2, "Undo");
    kaya_tx_set_menu_role(&tx, 2, "undo");
    kaya_tx_menu_item_create(&tx, 3, KAYA_MENU_KIND_ACTION);
    kaya_tx_set_menu_label(&tx, 3, "Redo");
    kaya_tx_set_menu_role(&tx, 3, "redo");
    kaya_tx_menu_item_append(&tx, 1, 2);
    kaya_tx_menu_item_append(&tx, 1, 3);
    kaya_tx_menubar_append(&tx, 0, 1);

    kaya_tx_create_signal(&tx, SIG_LAST, kaya_str("no answer yet"));
    kaya_tx_create_signal(&tx, SIG_COUNT, kaya_str("answers 0"));
    kaya_tx_create_signal(&tx, SIG_UNDONE, kaya_str("nothing undone"));
    kaya_tx_create_signal(&tx, SIG_ROWS, kaya_str("Milk, Eggs, Bread"));

    kaya_tx_create_widget(&tx, W_COLUMN, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, W_LAST, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_LAST, SIG_LAST);
    kaya_tx_create_widget(&tx, W_COUNT, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_COUNT, SIG_COUNT);
    kaya_tx_create_widget(&tx, W_UNDONE, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_UNDONE, SIG_UNDONE);
    kaya_tx_create_widget(&tx, W_ROWS, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_ROWS, SIG_ROWS);
    kaya_tx_create_widget(&tx, W_SHOW, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_SHOW, "show");
    kaya_tx_create_widget(&tx, W_FIRST, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_FIRST, "first");
    kaya_tx_create_widget(&tx, W_SECOND, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_SECOND, "second");
    kaya_tx_create_widget(&tx, W_DELETE, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_DELETE, "delete");
    kaya_tx_create_widget(&tx, W_HOLD, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_HOLD, "hold");
    kaya_tx_create_widget(&tx, W_DISMISS, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_DISMISS, "dismiss");

    kaya_tx_create_collection(&tx, C_ITEMS,
                              (KayaVariantSchema[]){{(uint32_t[]){KAYA_VALUE_STR}, 1}}, 1);
    kaya_tx_create_for(&tx, W_FOR_ITEMS, C_ITEMS);
    kaya_tx_create_widget(&tx, N_ROW, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, N_TITLE, KAYA_KIND_LABEL);
    kaya_tx_bind_text_element(&tx, N_TITLE, 0, F_TITLE);
    kaya_tx_add_child(&tx, N_ROW, N_TITLE);
    kaya_tx_template_end(&tx);

    kaya_tx_add_child(&tx, W_COLUMN, W_LAST);
    kaya_tx_add_child(&tx, W_COLUMN, W_COUNT);
    kaya_tx_add_child(&tx, W_COLUMN, W_UNDONE);
    kaya_tx_add_child(&tx, W_COLUMN, W_ROWS);
    kaya_tx_add_child(&tx, W_COLUMN, W_SHOW);
    kaya_tx_add_child(&tx, W_COLUMN, W_FIRST);
    kaya_tx_add_child(&tx, W_COLUMN, W_SECOND);
    kaya_tx_add_child(&tx, W_COLUMN, W_DELETE);
    kaya_tx_add_child(&tx, W_COLUMN, W_HOLD);
    kaya_tx_add_child(&tx, W_COLUMN, W_DISMISS);
    kaya_tx_add_child(&tx, W_COLUMN, W_FOR_ITEMS);
    kaya_tx_mount(&tx, 0, W_COLUMN);

    static const char *const initial[] = {"Milk", "Eggs", "Bread"};
    for (unsigned i = 0; i < 3; i++) {
        item_keys[i] = (int64_t)i + 1;
        snprintf(item_titles[i], MAX_TITLE, "%s", initial[i]);
        kaya_tx_collection_insert(&tx, C_ITEMS, 0, 0, kaya_i64(item_keys[i]), 0,
                                  (KayaVal[]){kaya_str(initial[i])}, 1);
    }
    n_items = 3;

    kaya_submit(tx.buf, tx.len);
}

static int key_index(int64_t key) {
    for (unsigned i = 0; i < n_items; i++)
        if (item_keys[i] == key)
            return (int)i;
    return -1;
}

static void str_copy(char *dst, size_t cap, const KayaVal *v) {
    size_t len = v->s_len < cap - 1 ? v->s_len : cap - 1;
    memcpy(dst, v->s, len);
    dst[len] = 0;
}

/* label#3, byte-frozen by tools/scenes/toast.steps. */
static void titles(char *out, size_t cap) {
    if (n_items == 0) {
        snprintf(out, cap, "empty");
        return;
    }
    size_t at = 0;
    out[0] = 0;
    for (unsigned i = 0; i < n_items && at < cap; i++)
        at += (size_t)snprintf(out + at, cap - at, i == 0 ? "%s" : ", %s",
                               item_titles[i]);
}

/* crates/kaya/src/spec.rs's `undone`, decoded as guests/c/undo.c does. */
typedef struct {
    uint32_t n_signals, n_texts, n_entries, n_orders;
    KayaVal label;
    size_t at;
} KayaUndo;

static int parse_undone(const uint8_t *rec, KayaUndo *u) {
    const KayaRecordHeader *h = (const KayaRecordHeader *)rec;
    if (h->kind != KAYA_OCCURRENCE_UNDONE)
        return 0;
    size_t at = sizeof(KayaRecordHeader) + 8;
    memcpy(&u->n_signals, rec + at, 4);
    at += 4;
    memcpy(&u->n_texts, rec + at, 4);
    at += 4;
    memcpy(&u->n_entries, rec + at, 4);
    at += 4;
    memcpy(&u->n_orders, rec + at, 4);
    at += 4;
    at = kaya_parse_value(rec, at, &u->label);
    u->at = at + 8;
    return 1;
}

static void fold_delta(const uint8_t *rec, const KayaUndo *u) {
    size_t at = u->at;
    KayaVal v;
    for (uint32_t i = 0; i < u->n_signals; i++) {
        at = kaya_parse_value(rec, at, &v);
        at = kaya_parse_value(rec, at, &v);
    }
    for (uint32_t i = 0; i < u->n_texts; i++) {
        KayaVal size;
        at = kaya_parse_value(rec, at, &size);
        for (int64_t k = 1; k < size.i; k++)
            at = kaya_parse_value(rec, at, &v);
    }
    for (uint32_t i = 0; i < u->n_entries; i++) {
        KayaVal size, collection, flags, variant, path_len, key;
        KayaVal title = kaya_str("");
        at = kaya_parse_value(rec, at, &size);
        at = kaya_parse_value(rec, at, &collection);
        at = kaya_parse_value(rec, at, &flags);
        at = kaya_parse_value(rec, at, &variant);
        at = kaya_parse_value(rec, at, &path_len);
        for (int64_t k = 0; k < path_len.i; k++)
            at = kaya_parse_value(rec, at, &v);
        at = kaya_parse_value(rec, at, &key);
        for (int64_t k = 6 + path_len.i; k < size.i; k++) {
            at = kaya_parse_value(rec, at, &v);
            if (k - (6 + path_len.i) == F_TITLE)
                title = v;
        }
        int index = key_index(key.i);
        if (flags.i & 1) {
            if (index < 0 && n_items < MAX_ITEMS) {
                index = (int)n_items;
                item_keys[index] = key.i;
                n_items += 1;
            }
            if (index >= 0)
                str_copy(item_titles[index], MAX_TITLE, &title);
        } else if (index >= 0) {
            for (unsigned k = (unsigned)index + 1; k < n_items; k++) {
                item_keys[k - 1] = item_keys[k];
                memcpy(item_titles[k - 1], item_titles[k], MAX_TITLE);
            }
            n_items -= 1;
        }
    }
    for (uint32_t i = 0; i < u->n_orders; i++) {
        KayaVal size, collection, path_len, key;
        at = kaya_parse_value(rec, at, &size);
        at = kaya_parse_value(rec, at, &collection);
        at = kaya_parse_value(rec, at, &path_len);
        for (int64_t k = 0; k < path_len.i; k++)
            at = kaya_parse_value(rec, at, &v);
        int64_t restated[MAX_ITEMS];
        unsigned n = 0;
        for (int64_t k = 3 + path_len.i; k < size.i; k++) {
            at = kaya_parse_value(rec, at, &key);
            if (n < MAX_ITEMS)
                restated[n++] = key.i;
        }
        if (path_len.i == 0) {
            char moved[MAX_ITEMS][MAX_TITLE];
            for (unsigned k = 0; k < n; k++) {
                int index = key_index(restated[k]);
                if (index >= 0)
                    memcpy(moved[k], item_titles[index], MAX_TITLE);
                else
                    moved[k][0] = 0;
            }
            memcpy(item_keys, restated, sizeof restated[0] * n);
            memcpy(item_titles, moved, (size_t)MAX_TITLE * n);
            n_items = n;
        }
    }
}

/* Header, toast id, u32 outcome (crates/kaya/src/spec.rs); the trailing
 * u32 is reserved and unread. */
static int parse_toast_result(const uint8_t *rec, uint64_t *toast,
                              uint32_t *outcome) {
    const KayaRecordHeader *h = (const KayaRecordHeader *)rec;
    if (h->kind != KAYA_OCCURRENCE_TOAST_RESULT)
        return 0;
    size_t at = sizeof(KayaRecordHeader);
    memcpy(toast, rec + at, 8);
    at += 8;
    memcpy(outcome, rec + at, 4);
    return 1;
}

/* What each live toast said, so its answer can name it. */
#define MAX_LIVE 8
static uint64_t live_ids[MAX_LIVE];
static char live_texts[MAX_LIVE][MAX_TITLE];

static void remember(uint64_t toast, const char *text) {
    unsigned slot = (unsigned)(toast % MAX_LIVE);
    live_ids[slot] = toast;
    snprintf(live_texts[slot], MAX_TITLE, "%s", text);
}

static void show(KayaTx *tx, uint64_t toast, uint32_t duration, uint32_t action,
                 const char *text, const char *label) {
    kaya_tx_show_toast(tx, 0, toast, duration, action, kaya_str(text),
                       kaya_str(label));
    remember(toast, text);
}

static void *app(void *arg) {
    (void)arg;
    build_scene();
    uint64_t toasts = 0, held = 0;
    unsigned answers = 0, undos = 0;
    const uint8_t *rec;
    for (;;) {
        size_t size = kaya_next_occurrence(&rec);
        if (size == 0)
            break; /* shutdown */
        if (size == KAYA_OCCURRENCE_WOKEN)
            continue; /* no record; rec is NULL */
        uint64_t id;
        KayaVal keys[2];
        uint32_t n_keys, outcome;
        uint8_t buf[1024];
        char text[192], list[MAX_ITEMS * (MAX_TITLE + 2)];
        KayaUndo undo;
        if (kaya_parse_click(rec, &id, keys, 2, &n_keys)) {
            if (n_keys != 0)
                continue;
            KayaTx tx = {buf, 0, sizeof buf};
            if (id == W_SHOW) {
                show(&tx, ++toasts, KAYA_TOAST_DURATION_SHORT, KAYA_TOAST_ACTION_NONE,
                     "Saved", "");
            } else if (id == W_FIRST) {
                show(&tx, ++toasts, KAYA_TOAST_DURATION_SHORT, KAYA_TOAST_ACTION_APP,
                     "First", "Open");
            } else if (id == W_SECOND) {
                show(&tx, ++toasts, KAYA_TOAST_DURATION_SHORT, KAYA_TOAST_ACTION_APP,
                     "Second", "Open");
            } else if (id == W_DELETE) {
                if (n_items == 0)
                    continue;
                char title[MAX_TITLE];
                snprintf(title, sizeof title, "%s", item_titles[0]);
                snprintf(text, sizeof text, "delete %s", title);
                /* AT THE FRONT OF THE BUFFER: an undo toast is refused
                 * outside an undo group. */
                kaya_tx_undo_group(&tx, 0, kaya_str(text));
                kaya_tx_collection_remove(&tx, C_ITEMS, 0, 0,
                                          kaya_i64(item_keys[0]));
                for (unsigned k = 1; k < n_items; k++) {
                    item_keys[k - 1] = item_keys[k];
                    memcpy(item_titles[k - 1], item_titles[k], MAX_TITLE);
                }
                n_items -= 1;
                titles(list, sizeof list);
                kaya_tx_write_signal(&tx, SIG_ROWS, kaya_str(list));
                snprintf(text, sizeof text, "Deleted %s", title);
                show(&tx, ++toasts, KAYA_TOAST_DURATION_SHORT, KAYA_TOAST_ACTION_UNDO,
                     text, "Undo");
            } else if (id == W_HOLD) {
                held = ++toasts;
                show(&tx, held, KAYA_TOAST_DURATION_LONG, KAYA_TOAST_ACTION_NONE,
                     "Working", "");
            } else if (id == W_DISMISS) {
                if (held == 0)
                    continue;
                kaya_tx_dismiss_toast(&tx, held);
                held = 0;
            } else {
                continue;
            }
            kaya_submit(tx.buf, tx.len);
        } else if (parse_toast_result(rec, &id, &outcome)) {
            unsigned slot = (unsigned)(id % MAX_LIVE);
            if (live_ids[slot] != id)
                continue;
            live_ids[slot] = 0;
            answers += 1;
            KayaTx tx = {buf, 0, sizeof buf};
            snprintf(text, sizeof text, "answers %u", answers);
            kaya_tx_write_signal(&tx, SIG_COUNT, kaya_str(text));
            snprintf(text, sizeof text, "%s: %s", live_texts[slot],
                     outcome == KAYA_TOAST_OUTCOME_ACTION ? "action" : "closed");
            kaya_tx_write_signal(&tx, SIG_LAST, kaya_str(text));
            kaya_submit(tx.buf, tx.len);
        } else if (parse_undone(rec, &undo)) {
            char name[MAX_TITLE];
            str_copy(name, sizeof name, &undo.label);
            fold_delta(rec, &undo);
            undos += 1;
            KayaTx tx = {buf, 0, sizeof buf};
            snprintf(text, sizeof text, "undone %u: %s", undos, name);
            kaya_tx_write_signal(&tx, SIG_UNDONE, kaya_str(text));
            titles(list, sizeof list);
            kaya_tx_write_signal(&tx, SIG_ROWS, kaya_str(list));
            kaya_submit(tx.buf, tx.len);
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
