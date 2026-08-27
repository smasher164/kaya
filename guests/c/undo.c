/* The undo scene from C, at the explicit wire floor: the undoable step
 * is kaya_tx_undo_group at the FRONT of the buffer, and the
 * undone/redone payload is decoded by hand (the generator emits no
 * parser for it). Reasoning: docs/undo-plan.md D2-D5 §3 and
 * docs/fresh-key-plan.md; semantics: guests/rust/undo.rs. Contract:
 * tools/scenes/undo.steps, where label#2 renders this app's key list and
 * label#3 its per-row notes. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* Guest-allocated ids. WIDGETS AND TEMPLATE NODES SHARE ONE SPACE, so the
 * N_ run continues the W_ one; signals, collections and menu items each
 * count from 1 in their own (DESIGN.md, Binding conventions).
 * CREATION ORDER IS CONTRACT: the keys label must be created third and
 * the notes label fourth for tools/scenes/undo.steps to read them.
 * Creating either later resolves the index to a STAMPED row label
 * instead of failing. */
#define SIG_STATUS 1
#define SIG_HISTORY 2
#define SIG_KEYS 3
#define SIG_NOTES 4

#define W_COLUMN 1
#define W_STATUS 2  /* label#0 */
#define W_HISTORY 3 /* label#1 */
#define W_KEYS 4    /* label#2 */
#define W_NOTES 5   /* label#3 */
#define W_FIELD 6   /* entry#0 */
#define W_ADD 7     /* button#0 */
#define W_STAR 8    /* button#1 */
#define W_FOCUS 9   /* button#2 */
#define W_REMOVE 10 /* button#3 */
#define W_FOR_TODOS 11

#define C_TODOS 1

#define N_ROW 12
#define N_TITLE 13
#define N_NOTE 14

#define F_TITLE 0

static void build_scene(void) {
    uint8_t buf[4096];
    KayaTx tx = {buf, 0, sizeof buf};

    {
        /* Packed by hand: the generated kaya_tx_set_window_prop closes
         * the record BEFORE the value. */
        size_t start = kaya_wire_begin(&tx, KAYA_TX_SET_WINDOW_PROP);
        kaya_wire_u64(&tx, 0);
        kaya_wire_u32(&tx, KAYA_WPROP_TITLE);
        kaya_wire_u32(&tx, KAYA_SOURCE_CONST);
        kaya_wire_value(&tx, kaya_str("undo"));
        kaya_wire_end(&tx, start);
    }
    /* Menu items live in their OWN id space; the roles are the closed
     * wire vocabulary. */
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

    kaya_tx_create_signal(&tx, SIG_STATUS, kaya_str("no todos"));
    kaya_tx_create_signal(&tx, SIG_HISTORY, kaya_str("history empty"));
    kaya_tx_create_signal(&tx, SIG_KEYS, kaya_str("no keys"));
    kaya_tx_create_signal(&tx, SIG_NOTES, kaya_str("no notes"));

    kaya_tx_create_widget(&tx, W_COLUMN, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, W_STATUS, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_STATUS, SIG_STATUS);
    kaya_tx_set_a11y_id(&tx, W_STATUS, "status");
    kaya_tx_create_widget(&tx, W_HISTORY, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_HISTORY, SIG_HISTORY);
    kaya_tx_set_a11y_id(&tx, W_HISTORY, "history");
    kaya_tx_create_widget(&tx, W_KEYS, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_KEYS, SIG_KEYS);
    kaya_tx_set_a11y_id(&tx, W_KEYS, "keys");
    kaya_tx_create_widget(&tx, W_NOTES, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_NOTES, SIG_NOTES);
    kaya_tx_set_a11y_id(&tx, W_NOTES, "notes");
    kaya_tx_create_widget(&tx, W_FIELD, KAYA_KIND_ENTRY);
    kaya_tx_set_a11y_id(&tx, W_FIELD, "draft");
    kaya_tx_create_widget(&tx, W_ADD, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_ADD, "add");
    kaya_tx_create_widget(&tx, W_STAR, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_STAR, "star");
    kaya_tx_create_widget(&tx, W_FOCUS, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_FOCUS, "focus");
    kaya_tx_create_widget(&tx, W_REMOVE, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_REMOVE, "remove");

    kaya_tx_create_collection(&tx, C_TODOS,
                              (KayaVariantSchema[]){{(uint32_t[]){KAYA_VALUE_STR}, 1}}, 1);
    kaya_tx_create_for(&tx, W_FOR_TODOS, C_TODOS);
    kaya_tx_create_widget(&tx, N_ROW, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, N_TITLE, KAYA_KIND_LABEL);
    kaya_tx_bind_text_element(&tx, N_TITLE, 0, F_TITLE);
    kaya_tx_add_child(&tx, N_ROW, N_TITLE);
    /* The row's own field, unbound: created after the title, so the row
     * reads title-then-field and the script's `entry#last` finds it. */
    kaya_tx_create_widget(&tx, N_NOTE, KAYA_KIND_ENTRY);
    kaya_tx_add_child(&tx, N_ROW, N_NOTE);
    kaya_tx_template_end(&tx);

    kaya_tx_add_child(&tx, W_COLUMN, W_STATUS);
    kaya_tx_add_child(&tx, W_COLUMN, W_HISTORY);
    kaya_tx_add_child(&tx, W_COLUMN, W_KEYS);
    kaya_tx_add_child(&tx, W_COLUMN, W_NOTES);
    kaya_tx_add_child(&tx, W_COLUMN, W_FIELD);
    kaya_tx_add_child(&tx, W_COLUMN, W_ADD);
    kaya_tx_add_child(&tx, W_COLUMN, W_STAR);
    kaya_tx_add_child(&tx, W_COLUMN, W_FOCUS);
    kaya_tx_add_child(&tx, W_COLUMN, W_REMOVE);
    kaya_tx_add_child(&tx, W_COLUMN, W_FOR_TODOS);
    /* The scene types with real keystrokes, so something has to be
     * holding focus when it does. */
    kaya_tx_widget_command(&tx, W_FIELD, KAYA_COMMAND_FOCUS);
    kaya_tx_mount(&tx, 0, W_COLUMN); /* window 0: the default */

    kaya_submit(tx.buf, tx.len);
}

/* The model, hand-kept per C's no-binding-model decision: the keys of
 * the collection, in order, and each entry's title beside it. */
#define MAX_TODOS 32
#define MAX_TITLE 128
static int64_t todo_keys[MAX_TODOS];
static char todo_titles[MAX_TODOS][MAX_TITLE];
static unsigned n_todos = 0;

/* What has been typed into the ROWS, by key — a row's field has no id
 * an app could hold, so the key indexes it. KEPT SORTED ASCENDING at
 * the insert: label#3 renders it in that order. */
#define MAX_NOTES MAX_TODOS
static int64_t note_keys[MAX_NOTES];
static char note_texts[MAX_NOTES][MAX_TITLE];
static unsigned n_notes = 0;

static int key_index(int64_t key) {
    for (unsigned i = 0; i < n_todos; i++)
        if (todo_keys[i] == key)
            return (int)i;
    return -1;
}

/* The wire's strings point into the record and are NOT terminated. */
static void str_copy(char *dst, size_t cap, const KayaVal *v) {
    size_t len = v->s_len < cap - 1 ? v->s_len : cap - 1;
    memcpy(dst, v->s, len);
    dst[len] = 0;
}

/* label#2, byte-frozen by tools/scenes/undo.steps. */
static void key_list(char *out, size_t cap) {
    if (n_todos == 0) {
        snprintf(out, cap, "no keys");
        return;
    }
    size_t at = (size_t)snprintf(out, cap, "keys ");
    for (unsigned i = 0; i < n_todos && at < cap; i++)
        at += (size_t)snprintf(out + at, cap - at, i == 0 ? "%lld" : ",%lld",
                               (long long)todo_keys[i]);
}

/* Both arrival paths call this — the row's own edit occurrence and the
 * texts run of an undone/redone payload. An empty text REMOVES the
 * key. */
static void note_set(int64_t key, const KayaVal *text) {
    unsigned i = 0;
    while (i < n_notes && note_keys[i] < key)
        i++;
    int found = i < n_notes && note_keys[i] == key;
    if (text->s_len == 0) {
        if (!found)
            return;
        for (unsigned k = i + 1; k < n_notes; k++) {
            note_keys[k - 1] = note_keys[k];
            memcpy(note_texts[k - 1], note_texts[k], MAX_TITLE);
        }
        n_notes -= 1;
        return;
    }
    if (!found) {
        if (n_notes >= MAX_NOTES)
            return;
        for (unsigned k = n_notes; k > i; k--) {
            note_keys[k] = note_keys[k - 1];
            memcpy(note_texts[k], note_texts[k - 1], MAX_TITLE);
        }
        note_keys[i] = key;
        n_notes += 1;
    }
    str_copy(note_texts[i], MAX_TITLE, text);
}

/* label#3, byte-frozen by tools/scenes/undo.steps. */
static void note_list(char *out, size_t cap) {
    if (n_notes == 0) {
        snprintf(out, cap, "no notes");
        return;
    }
    size_t at = (size_t)snprintf(out, cap, "notes ");
    for (unsigned i = 0; i < n_notes && at < cap; i++)
        at += (size_t)snprintf(out + at, cap - at,
                               i == 0 ? "%lld=%s" : ",%lld=%s",
                               (long long)note_keys[i], note_texts[i]);
}

/* An undone/redone body's fixed head, plus where its delta starts: the
 * shape is crates/kaya/src/spec.rs's `undone`. */
typedef struct {
    uint64_t window;
    uint32_t n_signals, n_texts, n_entries, n_orders;
    KayaVal label;
    size_t at; /* offset of the first delta value within the record */
} KayaUndo;

static int parse_undo(const uint8_t *rec, uint16_t kind, KayaUndo *u) {
    const KayaRecordHeader *h = (const KayaRecordHeader *)rec;
    if (h->kind != kind)
        return 0;
    size_t at = sizeof(KayaRecordHeader);
    memcpy(&u->window, rec + at, 8);
    at += 8;
    memcpy(&u->n_signals, rec + at, 4);
    at += 4;
    memcpy(&u->n_texts, rec + at, 4);
    at += 4;
    memcpy(&u->n_entries, rec + at, 4);
    at += 4;
    memcpy(&u->n_orders, rec + at, 4);
    at += 4;
    at = kaya_parse_value(rec, at, &u->label);
    /* +8 skips the flat list's own head, {u32 count, u32 reserved}. */
    u->at = at + 8;
    return 1;
}

/* Fold one undone/redone payload into this app's own state — the work a
 * binding does for a guest in the other eight languages. A delta STATES
 * the restored state, so folding it twice is folding it once. */
static void fold_delta(const uint8_t *rec, const KayaUndo *u, char *draft,
                       size_t draft_cap) {
    size_t at = u->at;
    KayaVal v;

    /* 1. signals: PAIRS of (I64 signal id, restored value). Nothing to
     *    fold — a signal's value at rest is the core's — but the run is
     *    walked, because the next one begins where it ends. */
    for (uint32_t i = 0; i < u->n_signals; i++) {
        at = kaya_parse_value(rec, at, &v);
        at = kaya_parse_value(rec, at, &v);
    }

    /* 2. texts: ARITY-FIRST groups —
     *
     *        I64 size    counting itself: 3 + path_len + 1
     *        I64 id      a widget id when path_len is 0, a TEMPLATE
     *                    NODE id when it is not
     *        I64 path_len
     *        path_len    values: the copy's key path, outermost first
     *        Str text    the restored text
     *
     *    (crates/kaya/src/wire.rs `undo_bodies_round_trip` pins the
     *    values one by one.) The tail is read by arity — `size` says
     *    where the group ends — so a group that grows later is walked
     *    past, not misread.
     *
     *    THE DELTA IS THE ONLY NOTIFICATION: a restore is a
     *    programmatic write and never echoes as text_changed, so an app
     *    that skips this run goes stale. */
    for (uint32_t i = 0; i < u->n_texts; i++) {
        KayaVal size, id, path_len, key;
        KayaVal text = kaya_str("");
        int64_t row = 0;
        at = kaya_parse_value(rec, at, &size);
        at = kaya_parse_value(rec, at, &id);
        at = kaya_parse_value(rec, at, &path_len);
        for (int64_t k = 0; k < path_len.i; k++) {
            at = kaya_parse_value(rec, at, &key);
            if (k == 0)
                row = key.i;
        }
        for (int64_t k = 3 + path_len.i; k < size.i; k++) {
            at = kaya_parse_value(rec, at, &v);
            if (k == 3 + path_len.i)
                text = v;
        }
        if (path_len.i == 0) {
            if (id.i == (int64_t)W_FIELD) {
                size_t len = text.s_len < draft_cap - 1 ? text.s_len : draft_cap - 1;
                memcpy(draft, text.s, len);
                draft[len] = 0;
            }
        } else {
            note_set(row, &text);
        }
    }

    /* 3. entries: ARITY-FIRST groups — I64 size (counting itself),
     *    collection, flags (bit 0 = the entry EXISTS), variant,
     *    path_len, path_len instance-path keys, the entry's key, then
     *    the record's fields. A restored entry carries its record and a
     *    removed one carries none, so `size` is 6 + path + fields for
     *    the first and 6 + path for the second. */
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
        /* The fields: 5 fixed ints + the path + the key are read. */
        for (int64_t k = 6 + path_len.i; k < size.i; k++) {
            at = kaya_parse_value(rec, at, &v);
            if (k - (6 + path_len.i) == F_TITLE)
                title = v;
        }
        int index = key_index(key.i);
        if (flags.i & 1) {
            /* THE KEY IS THE ONE THE ENTRY ALREADY HAD — the core kept it,
             * so nothing here mints. */
            if (index < 0 && n_todos < MAX_TODOS) {
                index = (int)n_todos;
                todo_keys[index] = key.i;
                n_todos += 1;
            }
            if (index >= 0)
                str_copy(todo_titles[index], MAX_TITLE, &title);
        } else if (index >= 0) {
            for (unsigned k = (unsigned)index + 1; k < n_todos; k++) {
                todo_keys[k - 1] = todo_keys[k];
                memcpy(todo_titles[k - 1], todo_titles[k], MAX_TITLE);
            }
            n_todos -= 1;
        }
    }

    /* 4. orders: ARITY-FIRST likewise — I64 size, collection, path_len,
     *    path keys, then the instance's keys IN ORDER. "Changed the
     *    order" INCLUDES an insert or a remove
     *    (crates/kaya/src/spec.rs), so every group delta in this scene
     *    carries one; position is what a per-entry statement cannot
     *    carry. */
    for (uint32_t i = 0; i < u->n_orders; i++) {
        KayaVal size, collection, path_len, key;
        at = kaya_parse_value(rec, at, &size);
        at = kaya_parse_value(rec, at, &collection);
        at = kaya_parse_value(rec, at, &path_len);
        for (int64_t k = 0; k < path_len.i; k++)
            at = kaya_parse_value(rec, at, &v);
        int64_t restated[MAX_TODOS];
        unsigned n = 0;
        for (int64_t k = 3 + path_len.i; k < size.i; k++) {
            at = kaya_parse_value(rec, at, &key);
            if (n < MAX_TODOS)
                restated[n++] = key.i;
        }
        /* A top-level instance is this app's whole list (path_len 0). The
         * run states positions only, so each restated key's title is
         * looked up in the model the entries run just updated. */
        if (path_len.i == 0) {
            char titles[MAX_TODOS][MAX_TITLE];
            for (unsigned k = 0; k < n; k++) {
                int index = key_index(restated[k]);
                if (index >= 0)
                    memcpy(titles[k], todo_titles[index], MAX_TITLE);
                else
                    titles[k][0] = 0;
            }
            memcpy(todo_keys, restated, sizeof restated[0] * n);
            memcpy(todo_titles, titles, (size_t)MAX_TITLE * n);
            n_todos = n;
        }
    }
}

/* What the history label says a step was. A typing episode has no
 * authored name and kaya invents none, so the empty label is the app's
 * to spell. The label points into the record, unterminated. */
static const char *what(const KayaVal *label, char *buf, size_t cap) {
    if (label->s_len == 0)
        return "typing";
    size_t len = label->s_len < cap - 1 ? label->s_len : cap - 1;
    memcpy(buf, label->s, len);
    buf[len] = 0;
    return buf;
}

static void *app(void *arg) {
    (void)arg;
    build_scene();
    char draft[128] = "";
    /* The minter the sugar bindings spell `insert_fresh`, hand-kept — one
     * counter per collection instance (docs/fresh-key-plan.md). NOTHING
     * DECREMENTS IT: undo and redo replay captured keys inside the core
     * and never re-enter this handler. */
    int64_t fresh = 0;
    const uint8_t *rec;
    for (;;) {
        size_t size = kaya_next_occurrence(&rec);
        if (size == 0)
            break; /* shutdown */
        if (size == KAYA_OCCURRENCE_WOKEN)
            continue; /* no record; rec is NULL */
        uint64_t id;
        KayaVal keys[2], text;
        uint32_t n_keys;
        /* The floor sizes its buffers rather than growing them: wide
         * enough for every label one transaction writes, notes included,
         * and for MAX_TODOS spelled-out keys and `key=text` notes. */
        uint8_t buf[8192];
        char status[192];
        char keys_text[768];
        char notes_text[MAX_NOTES * (MAX_TITLE + 24)];
        KayaUndo undo;
        if (kaya_parse_text_changed(rec, &id, keys, 2, &n_keys, &text)) {
            /* The two fields, told apart by the path: empty is the live
             * widget, a path names a stamped copy under a node id. */
            if (id == W_FIELD && n_keys == 0) {
                unsigned len = text.s_len < sizeof draft - 1
                    ? text.s_len : (unsigned)sizeof draft - 1;
                memcpy(draft, text.s, len);
                draft[len] = 0;
            } else if (id == N_NOTE && n_keys > 0) {
                /* NOT an undoable transaction: the typing is the step, and
                 * a group here would bank a second one per keystroke. */
                note_set(keys[0].i, &text);
                KayaTx tx = {buf, 0, sizeof buf};
                note_list(notes_text, sizeof notes_text);
                kaya_tx_write_signal(&tx, SIG_NOTES, kaya_str(notes_text));
                kaya_submit(tx.buf, tx.len);
            }
        } else if (kaya_parse_click(rec, &id, keys, 2, &n_keys)) {
            if (n_keys != 0)
                continue;
            if (id == W_ADD) {
                KayaTx tx = {buf, 0, sizeof buf};
                /* The empty-draft guard, and NOT an undoable step. */
                if (draft[0] == '\0') {
                    snprintf(status, sizeof status, "nothing to add, %u total",
                             n_todos);
                    kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str(status));
                    kaya_submit(tx.buf, tx.len);
                    continue;
                }
                fresh += 1;
                int64_t key = fresh;
                char step[160];
                snprintf(step, sizeof step, "add %s", draft);
                /* AT THE FRONT OF THE BUFFER: everything after it in this
                 * batch is what the step did. */
                kaya_tx_undo_group(&tx, 0, kaya_str(step));
                kaya_tx_collection_insert(&tx, C_TODOS, 0, 0, kaya_i64(key), 0,
                                          (KayaVal[]){kaya_str(draft)}, 1);
                if (n_todos < MAX_TODOS) {
                    todo_keys[n_todos] = key;
                    snprintf(todo_titles[n_todos], MAX_TITLE, "%s", draft);
                    n_todos += 1;
                }
                snprintf(status, sizeof status, "added %s, %u total", draft,
                         n_todos);
                kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str(status));
                key_list(keys_text, sizeof keys_text);
                kaya_tx_write_signal(&tx, SIG_KEYS, kaya_str(keys_text));
                kaya_tx_widget_command(&tx, W_FIELD, KAYA_COMMAND_FOCUS);
                kaya_submit(tx.buf, tx.len);
                /* Finishing the form gets its OWN transaction: `clear`
                 * inside an undo group is REFUSED at apply, destroying
                 * widget-owned text the core never held. */
                uint8_t finish[64];
                KayaTx form = {finish, 0, sizeof finish};
                kaya_tx_widget_command(&form, W_FIELD, KAYA_COMMAND_CLEAR);
                kaya_submit(form.buf, form.len);
            } else if (id == W_REMOVE) {
                /* Which entry is first is the MODEL's answer, never a
                 * widget's. */
                KayaTx tx = {buf, 0, sizeof buf};
                if (n_todos == 0) {
                    snprintf(status, sizeof status, "nothing to remove, %u total",
                             n_todos);
                    kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str(status));
                    kaya_submit(tx.buf, tx.len);
                    continue;
                }
                char step[160], title[MAX_TITLE];
                snprintf(title, sizeof title, "%s", todo_titles[0]);
                snprintf(step, sizeof step, "remove %s", title);
                /* The app remembers neither the key nor the position: the
                 * core captured both and hands them back in the delta. */
                kaya_tx_undo_group(&tx, 0, kaya_str(step));
                kaya_tx_collection_remove(&tx, C_TODOS, 0, 0,
                                          kaya_i64(todo_keys[0]));
                for (unsigned k = 1; k < n_todos; k++) {
                    todo_keys[k - 1] = todo_keys[k];
                    memcpy(todo_titles[k - 1], todo_titles[k], MAX_TITLE);
                }
                n_todos -= 1;
                snprintf(status, sizeof status, "removed %s, %u total", title,
                         n_todos);
                kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str(status));
                key_list(keys_text, sizeof keys_text);
                kaya_tx_write_signal(&tx, SIG_KEYS, kaya_str(keys_text));
                kaya_submit(tx.buf, tx.len);
            } else if (id == W_STAR) {
                /* A group at its smallest: one signal write. */
                KayaTx tx = {buf, 0, sizeof buf};
                kaya_tx_undo_group(&tx, 0, kaya_str("star"));
                kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str("starred"));
                kaya_submit(tx.buf, tx.len);
            } else if (id == W_FOCUS) {
                KayaTx tx = {buf, 0, sizeof buf};
                kaya_tx_widget_command(&tx, W_FIELD, KAYA_COMMAND_FOCUS);
                kaya_submit(tx.buf, tx.len);
            }
        } else if (parse_undo(rec, KAYA_OCCURRENCE_UNDONE, &undo)) {
            /* The fold runs BEFORE the transaction is built: the record's
             * bytes are the core's and live only until the next
             * kaya_next_occurrence. */
            char name[128];
            const char *step = what(&undo.label, name, sizeof name);
            fold_delta(rec, &undo, draft, sizeof draft);
            KayaTx tx = {buf, 0, sizeof buf};
            snprintf(status, sizeof status, "undid %s, %u total", step, n_todos);
            kaya_tx_write_signal(&tx, SIG_HISTORY, kaya_str(status));
            /* Keys and notes ride the SAME transaction as the history
             * label: the script reads history first, so what it then
             * reads is the app's own answer and not the value the core
             * restored on its way past. */
            key_list(keys_text, sizeof keys_text);
            kaya_tx_write_signal(&tx, SIG_KEYS, kaya_str(keys_text));
            note_list(notes_text, sizeof notes_text);
            kaya_tx_write_signal(&tx, SIG_NOTES, kaya_str(notes_text));
            kaya_submit(tx.buf, tx.len);
        } else if (parse_undo(rec, KAYA_OCCURRENCE_REDONE, &undo)) {
            char name[128];
            const char *step = what(&undo.label, name, sizeof name);
            fold_delta(rec, &undo, draft, sizeof draft);
            KayaTx tx = {buf, 0, sizeof buf};
            snprintf(status, sizeof status, "redid %s, %u total", step, n_todos);
            kaya_tx_write_signal(&tx, SIG_HISTORY, kaya_str(status));
            key_list(keys_text, sizeof keys_text);
            kaya_tx_write_signal(&tx, SIG_KEYS, kaya_str(keys_text));
            note_list(notes_text, sizeof notes_text);
            kaya_tx_write_signal(&tx, SIG_NOTES, kaya_str(notes_text));
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
