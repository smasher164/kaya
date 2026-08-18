/* The todos scene from C, on the function floor: records and field
 * projection with indexes spelled by hand. The derive the eight sugar
 * bindings recompute for their guest is write_items_left here, packed
 * into the CALLER'S transaction so the count rides the mutation's batch
 * — which is why the undone/redone arm folds the delta and writes
 * nothing (docs/deferred.md's retracted "a derived signal goes stale
 * after an undo").
 *
 * Built and run by the Linux container suite with KAYA_SELFTEST=todos. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* Guest-allocated ids, counted from 1 per space. */
#define SIG_LEFT 1
#define W_COLUMN 1
#define W_FIELD 2
#define W_ADD 3
#define W_STATUS 4
#define W_FOR_TODOS 5
#define C_TODOS 1
#define N_ROW 1
#define N_CHECK 2
#define N_TITLE 3

/* Menu items live in their OWN id space, never the widget one. */
#define M_EDIT 1
#define M_UNDO 2
#define M_REDO 3

#define F_TITLE 0
#define F_DONE 1

static void build_scene(void) {
    /* Overflow is the caller's to size against: the packers write
     * through a bare pointer and nothing bounds-checks (kaya_wire.h). */
    uint8_t buf[4096];
    KayaTx tx = {buf, 0};

    {
        /* Packed by hand: the generated kaya_tx_set_window_prop closes
         * the record BEFORE the value. */
        size_t start = kaya_wire_begin(&tx, KAYA_TX_SET_WINDOW_PROP);
        kaya_wire_u64(&tx, 0);
        kaya_wire_u32(&tx, KAYA_WPROP_TITLE);
        kaya_wire_u32(&tx, KAYA_SOURCE_CONST);
        kaya_wire_value(&tx, kaya_str("todos"));
        kaya_wire_end(&tx, start);
    }
    /* The whole undo surface this app declares: two items with the
     * closed wire roles. No handler answers them and no signal tracks
     * their enablement — the platform works both out. */
    kaya_tx_menu_item_create(&tx, M_EDIT, KAYA_MENU_KIND_MENU);
    kaya_tx_set_menu_label(&tx, M_EDIT, "Edit");
    kaya_tx_menu_item_create(&tx, M_UNDO, KAYA_MENU_KIND_ACTION);
    kaya_tx_set_menu_label(&tx, M_UNDO, "Undo");
    kaya_tx_set_menu_role(&tx, M_UNDO, "undo");
    kaya_tx_menu_item_create(&tx, M_REDO, KAYA_MENU_KIND_ACTION);
    kaya_tx_set_menu_label(&tx, M_REDO, "Redo");
    kaya_tx_set_menu_role(&tx, M_REDO, "redo");
    kaya_tx_menu_item_append(&tx, M_EDIT, M_UNDO);
    kaya_tx_menu_item_append(&tx, M_EDIT, M_REDO);
    kaya_tx_menubar_append(&tx, 0, M_EDIT);

    kaya_tx_create_signal(&tx, SIG_LEFT, kaya_str("0 items left"));
    kaya_tx_create_widget(&tx, W_COLUMN, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, W_FIELD, KAYA_KIND_ENTRY);
    kaya_tx_create_widget(&tx, W_ADD, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_ADD, "Add");
    /* CREATION ORDER IS CONTRACT: the script reads label#0, and the
     * status label is first only because the template's title label is
     * stamped later. */
    kaya_tx_create_widget(&tx, W_STATUS, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_STATUS, SIG_LEFT);

    kaya_tx_create_collection(
        &tx, C_TODOS,
        (KayaVariantSchema[]){{(uint32_t[]){KAYA_VALUE_STR, KAYA_VALUE_BOOL}, 2}}, 1);
    kaya_tx_create_for(&tx, W_FOR_TODOS, C_TODOS);
    kaya_tx_create_widget(&tx, N_ROW, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, N_CHECK, KAYA_KIND_CHECKBOX);
    kaya_tx_bind_checked_element(&tx, N_CHECK, 0, F_DONE);
    kaya_tx_create_widget(&tx, N_TITLE, KAYA_KIND_LABEL);
    kaya_tx_bind_text_element(&tx, N_TITLE, 0, F_TITLE);
    kaya_tx_add_child(&tx, N_ROW, N_CHECK);
    kaya_tx_add_child(&tx, N_ROW, N_TITLE);
    kaya_tx_template_end(&tx);

    kaya_tx_add_child(&tx, W_COLUMN, W_FIELD);
    kaya_tx_add_child(&tx, W_COLUMN, W_ADD);
    kaya_tx_add_child(&tx, W_COLUMN, W_STATUS);
    kaya_tx_add_child(&tx, W_COLUMN, W_FOR_TODOS);
    kaya_tx_mount(&tx, 0, W_COLUMN); /* window 0: the default */

    kaya_submit(tx.buf, tx.len);
}

/* The model, hand-kept per C's no-binding-model decision. */
#define MAX_TODOS 32
typedef struct {
    char key[16];
    int done;
} Todo;
static Todo todos[MAX_TODOS];
static unsigned n_todos = 0;

/* The keys are Str and a parsed Str points into the record WITHOUT a
 * terminator, so every lookup goes through here, never strcmp. */
static int key_index(const KayaVal *key) {
    for (unsigned i = 0; i < n_todos; i++)
        if (key->s_len == strlen(todos[i].key) &&
            memcmp(key->s, todos[i].key, key->s_len) == 0)
            return (int)i;
    return -1;
}

static void str_copy(char *dst, size_t cap, const KayaVal *v) {
    size_t len = v->s_len < cap - 1 ? v->s_len : cap - 1;
    memcpy(dst, v->s, len);
    dst[len] = 0;
}

/* Takes the CALLER'S transaction, so the recomputed count lands in the
 * same batch as the mutation and is banked with it. Called from the two
 * mutation handlers and from nowhere else — never from the undo path,
 * where the core has already restored what this would compute. */
static void write_items_left(KayaTx *tx) {
    unsigned left = 0;
    for (unsigned i = 0; i < n_todos; i++)
        if (!todos[i].done)
            left += 1;
    char status[32];
    snprintf(status, sizeof status, left == 1 ? "%u item left" : "%u items left",
             left);
    kaya_tx_write_signal(tx, SIG_LEFT, kaya_str(status));
}

/* An undone/redone body's fixed head, plus where its delta starts: the
 * shape is crates/kaya/src/spec.rs's `undone`, decoded run by run in
 * guests/c/undo.c, which reads the same record. */
typedef struct {
    uint64_t window;
    uint32_t n_signals, n_texts, n_entries, n_orders;
    KayaVal label; /* the step's name; this app renders no history */
    size_t at;     /* offset of the first delta value within the record */
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
    /* +8 skips the flat list's own head, {u32 count, u32 reserved}: the
     * run counts above already say how the values divide. */
    u->at = at + 8;
    return 1;
}

/* Fold one undone/redone payload into this app's own model — the work
 * the other eight bindings do in absorb_undo before the guest's handler
 * runs (crates/kaya/src/app.rs). A delta STATES the restored state, so
 * folding it twice is folding it once. */
static void fold_delta(const uint8_t *rec, const KayaUndo *u, char *draft,
                       size_t draft_cap) {
    size_t at = u->at;
    KayaVal v, w;

    /* 1. signals: PAIRS of (I64 signal id, restored value). NOTHING TO
     *    FOLD AND NOTHING TO RECOMPUTE. One of the pairs walked past is
     *    SIG_LEFT — the count write_items_left made inside the add's
     *    group, banked with the insert and already restored. Calling
     *    write_items_left here would write a value the ledger never
     *    banked. The run is still walked, because the next one begins
     *    where it ends. */
    for (uint32_t i = 0; i < u->n_signals; i++) {
        at = kaya_parse_value(rec, at, &v);
        at = kaya_parse_value(rec, at, &v);
    }

    /* 2. texts: PAIRS of (I64 widget id, restored Str). Empty in this
     *    scene and folded anyway — a restore is a programmatic write and
     *    never echoes as text_changed, so the delta is the only
     *    notification an uncontrolled field's mirror gets.
     *    guests/c/undo.c is where this run carries something. */
    for (uint32_t i = 0; i < u->n_texts; i++) {
        at = kaya_parse_value(rec, at, &v);
        at = kaya_parse_value(rec, at, &w);
        if (v.i == (int64_t)W_FIELD)
            str_copy(draft, draft_cap, &w);
    }

    /* 3. entries: ARITY-FIRST groups — I64 size (counting itself),
     *    collection, flags (bit 0 = the entry EXISTS), variant,
     *    path_len, path_len instance-path keys, the entry's key, then
     *    the record's fields. This app models one of the two, `done`.
     *    A restored entry carries its record and a removed one carries
     *    none, so `size` is 6 + path + fields for the first and 6 + path
     *    for the second. */
    for (uint32_t i = 0; i < u->n_entries; i++) {
        KayaVal size, collection, flags, variant, path_len, key;
        KayaVal done = kaya_bool(0);
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
            if (k - (6 + path_len.i) == F_DONE)
                done = v;
        }
        int index = key_index(&key);
        if (flags.i & 1) {
            /* THE KEY IS THE ONE THE ENTRY ALREADY HAD: the core kept
             * it, so nothing here mints and the minter in `app` below
             * never hears about a history walk. */
            if (index < 0 && n_todos < MAX_TODOS) {
                index = (int)n_todos;
                str_copy(todos[index].key, sizeof todos[index].key, &key);
                n_todos += 1;
            }
            if (index >= 0)
                todos[index].done = done.i != 0;
        } else if (index >= 0) {
            for (unsigned k = (unsigned)index + 1; k < n_todos; k++)
                todos[k - 1] = todos[k];
            n_todos -= 1;
        }
    }

    /* 4. orders: ARITY-FIRST likewise — I64 size, collection, path_len,
     *    path keys, then the instance's keys IN ORDER. "Changed the
     *    order" includes an insert or a remove
     *    (crates/kaya/src/spec.rs), so this scene's add carries one even
     *    though the app only ever appends. Folded because position is
     *    what a per-entry statement cannot carry. */
    for (uint32_t i = 0; i < u->n_orders; i++) {
        KayaVal size, collection, path_len, key;
        at = kaya_parse_value(rec, at, &size);
        at = kaya_parse_value(rec, at, &collection);
        at = kaya_parse_value(rec, at, &path_len);
        for (int64_t k = 0; k < path_len.i; k++)
            at = kaya_parse_value(rec, at, &v);
        Todo restated[MAX_TODOS];
        unsigned n = 0;
        for (int64_t k = 3 + path_len.i; k < size.i; k++) {
            at = kaya_parse_value(rec, at, &key);
            if (n >= MAX_TODOS)
                continue;
            /* Each restated key brings its own `done` with it, looked up
             * in the model the entries run just updated. */
            int index = key_index(&key);
            if (index >= 0)
                restated[n] = todos[index];
            else {
                str_copy(restated[n].key, sizeof restated[n].key, &key);
                restated[n].done = 0;
            }
            n += 1;
        }
        /* A top-level instance is this app's whole list (path_len 0). */
        if (path_len.i == 0) {
            memcpy(todos, restated, sizeof restated[0] * n);
            n_todos = n;
        }
    }
}

static void *app(void *arg) {
    (void)arg;
    build_scene();
    char draft[128] = "";
    /* The minter the sugar bindings spell `insert_fresh`, hand-kept
     * (docs/fresh-key-plan.md). NOTHING DECREMENTS IT: undo and redo
     * replay captured keys inside the core and never re-enter this
     * handler, so counting the model instead would rewind on an undo and
     * hand one name to two todos. */
    unsigned fresh = 0;
    const uint8_t *rec;
    for (;;) {
        size_t size = kaya_next_occurrence(&rec);
        if (size == 0)
            break; /* shutdown */
        if (size == KAYA_OCCURRENCE_WOKEN)
            continue; /* no record; rec is NULL */
        uint64_t id;
        KayaVal keys[2], payload;
        uint32_t n_keys;
        KayaUndo undo;
        if (kaya_parse_text_changed(rec, &id, keys, 2, &n_keys, &payload)) {
            if (id == W_FIELD && n_keys == 0)
                str_copy(draft, sizeof draft, &payload);
        } else if (kaya_parse_toggled(rec, &id, keys, 2, &n_keys, &payload)) {
            if (id == N_CHECK && n_keys == 1) {
                int index = key_index(&keys[0]);
                if (index >= 0)
                    todos[index].done = payload.i != 0;
                uint8_t buf[512];
                KayaTx tx = {buf, 0};
                /* The 0 after F_DONE is the witnessed variant — a record
                 * collection has one constructor. */
                kaya_tx_collection_update_field(&tx, C_TODOS, 0, 0, keys[0],
                                                F_DONE, 0,
                                                kaya_bool(payload.i != 0));
                write_items_left(&tx);
                kaya_submit(tx.buf, tx.len);
            }
        } else if (kaya_parse_click(rec, &id, keys, 2, &n_keys)) {
            if (id == W_ADD && n_keys == 0 && n_todos < MAX_TODOS) {
                /* The empty-draft guard, and NOT an undoable step: a
                 * refused add is not a step a user expects back. */
                if (draft[0] == '\0')
                    continue;
                char step[160];
                snprintf(step, sizeof step, "add %s", draft);
                fresh += 1;
                snprintf(todos[n_todos].key, sizeof todos[n_todos].key, "t%u",
                         fresh);
                todos[n_todos].done = 0;
                n_todos += 1;
                uint8_t buf[512];
                KayaTx tx = {buf, 0};
                /* AT THE FRONT OF THE BUFFER: everything after it is
                 * what the step did — the insert, and the count the
                 * insert changed. */
                kaya_tx_undo_group(&tx, 0, kaya_str(step));
                kaya_tx_collection_insert(
                    &tx, C_TODOS, 0, 0, kaya_str(todos[n_todos - 1].key), 0,
                    (KayaVal[]){kaya_str(draft), kaya_bool(0)}, 2);
                write_items_left(&tx);
                kaya_submit(tx.buf, tx.len);
                /* Finishing the form gets its OWN transaction: `clear`
                 * inside an undo group is REFUSED at apply, destroying
                 * widget-owned text the core never held. The field then
                 * reports text_changed("") and the branch above empties
                 * the draft. */
                uint8_t finish[128];
                KayaTx form = {finish, 0};
                kaya_tx_widget_command(&form, W_FIELD, KAYA_COMMAND_CLEAR);
                kaya_tx_widget_command(&form, W_FIELD, KAYA_COMMAND_FOCUS);
                kaya_submit(form.buf, form.len);
            }
        } else if (parse_undo(rec, KAYA_OCCURRENCE_UNDONE, &undo) ||
                   parse_undo(rec, KAYA_OCCURRENCE_REDONE, &undo)) {
            /* THE FOLD AND NOTHING ELSE, IN BOTH DIRECTIONS: no signal
             * write, no recompute, no transaction. The label the script
             * reads after Edit>Undo and Edit>Redo is the core's, banked
             * into the add's group. Both directions want the same fold —
             * a delta says what things now ARE. */
            fold_delta(rec, &undo, draft, sizeof draft);
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
