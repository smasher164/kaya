/* The todos scene from C, on the function floor: records and field
 * projection with indexes spelled by hand — the desugared form every
 * derive lowers to. The collection declares a {Str, Bool} schema, the
 * template binds field 0 to a label and field 1 to a checkbox, and the
 * toggle handler sends one field's delta — the title never travels.
 *
 * THE DERIVED LABEL IS HAND-WRITTEN HERE, AND THAT IS WHAT MAKES THIS
 * FILE THE ARGUMENT. The eight sugar bindings declare "items left" with
 * collection.derive and their binding recomputes it after every
 * mutation, writing the new value INTO THE SAME TRANSACTION as the
 * mutation. The floor takes no sugar (invariant 5), so what that sugar
 * lowers to is written out: write_items_left packs an ordinary
 * write_signal into the CALLER'S transaction, beside the insert or the
 * field update that changed the count. One batch, not two.
 *
 * WHICH IS WHY THE UNDO BELOW ASKS FOR NO CODE. The add is a named step
 * — kaya_tx_undo_group at the front of the buffer — so the group holds
 * the insert AND the signal write the insert caused, and the core banks
 * both in each direction of that step. Edit>Undo restores the label
 * together with the collection it counts; Edit>Redo puts both back. The
 * undone/redone handlers at the bottom fold the delta into this app's
 * own model and write NOTHING: no recompute, no write_items_left, no
 * transaction at all. docs/deferred.md carries the retracted "a derived
 * signal goes stale after an undo" defect, and the two label readings
 * around the menu activations in tools/scenes/todos.steps are what
 * replaced it.
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

/* The record's field indexes: the C floor's "field tokens". */
#define F_TITLE 0
#define F_DONE 1

static void build_scene(void) {
    /* Sized for the menu, which is a third of these records. Overflow is
     * the caller's to size against down here (kaya_wire.h:13-15): the
     * packers write through a bare pointer and nothing bounds-checks. */
    uint8_t buf[4096];
    KayaTx tx = {buf, 0};

    {
        /* set_window_prop, raw wire: u64 window, u32 wprop, u32 source,
         * value — the generated packer closes the record without one. */
        size_t start = kaya_wire_begin(&tx, KAYA_TX_SET_WINDOW_PROP);
        kaya_wire_u64(&tx, 0);
        kaya_wire_u32(&tx, KAYA_WPROP_TITLE);
        kaya_wire_u32(&tx, KAYA_SOURCE_CONST);
        kaya_wire_value(&tx, kaya_str("todos"));
        kaya_wire_end(&tx, start);
    }
    /* THE WHOLE UNDO SURFACE THIS APP DECLARES: two items with the
     * closed wire roles, hand-spelled at this floor. They act on the
     * focused widget, lower to the platform's own command where it has
     * one, and work out their own enablement from what is focused and
     * what the ledger holds — so no handler here answers them and no
     * signal here tracks whether they should be grey. */
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
    /* CREATION ORDER IS CONTRACT: the harness addresses label#0, and the
     * status label is the first label created only because the
     * template's title label is stamped later. */
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

/* The model, hand-kept per C's no-binding-model decision. In the eight
 * sugar bindings this array is the binding's collection mirror and the
 * app never sees it; here the app IS the mirror, which is why the undo
 * fold below exists at all. */
#define MAX_TODOS 32
typedef struct {
    char key[16];
    int done;
} Todo;
static Todo todos[MAX_TODOS];
static unsigned n_todos = 0;

/* ONE key comparison for the whole file: the collection's keys are Str
 * and a parsed Str points into the record without a terminator, so
 * every lookup goes through here rather than through strcmp. */
static int key_index(const KayaVal *key) {
    for (unsigned i = 0; i < n_todos; i++)
        if (key->s_len == strlen(todos[i].key) &&
            memcmp(key->s, todos[i].key, key->s_len) == 0)
            return (int)i;
    return -1;
}

/* A value's bytes into a NUL-terminated buffer. */
static void str_copy(char *dst, size_t cap, const KayaVal *v) {
    size_t len = v->s_len < cap - 1 ? v->s_len : cap - 1;
    memcpy(dst, v->s, len);
    dst[len] = 0;
}

/* THE DERIVE, DESUGARED. It takes the caller's transaction rather than
 * opening one, and that parameter is the whole mechanism this scene
 * pins: the recomputed value goes into the SAME batch as the mutation
 * that invalidated it, so a batch that is also a named step banks the
 * count in both directions along with the entries it counts. Called
 * from the two mutation handlers and from nowhere else — never from the
 * undo path, where the core has already restored what this would
 * compute. */
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

/* An undone/redone body's fixed head, plus where its delta starts. The
 * shape is spec.rs's `undone`: window, four RUN COUNTS, the label, then
 * one flat value list read as those four runs in order. Annotated at
 * length in guests/c/undo.c, which reads the same record. */
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
    /* The flat list is a counted value sequence: {u32 count, u32
     * reserved, count values}. The counts above already say how the
     * values divide, so the total is skipped rather than trusted. */
    u->at = at + 8;
    return 1;
}

/* Fold one undone/redone payload into this app's own model — the work
 * the other eight bindings do in absorb_undo before the guest's handler
 * runs (crates/kaya/src/app.rs), and which C has no binding to do for
 * it. Entries and orders, in that order, exactly the two runs that
 * binding folds.
 *
 * A STATEMENT OF THE RESTORED STATE, NOT A REPLAY OF OPS: every group
 * says what a thing now IS, so applying this twice is the same as
 * applying it once, and nothing here re-derives anything. */
static void fold_delta(const uint8_t *rec, const KayaUndo *u, char *draft,
                       size_t draft_cap) {
    size_t at = u->at;
    KayaVal v, w;

    /* 1. signals: PAIRS of (I64 signal id, restored value). NOTHING TO
     *    FOLD AND NOTHING TO RECOMPUTE, and both halves of that are
     *    deliberate.
     *
     *    Nothing to fold, because a signal's value at rest is the
     *    core's and every widget bound to it has already been updated;
     *    no binding mirrors signals either.
     *
     *    NOTHING TO RECOMPUTE IS THE PART THIS SCENE EXISTS FOR. One of
     *    the pairs walked past here is SIG_LEFT, and it is the count
     *    write_items_left made inside the add's group — banked with the
     *    insert, restored with it, and already on screen by the time
     *    this runs. Calling write_items_left here would write a value
     *    the ledger never banked, in a transaction the app never asked
     *    for. Agreeing with the restored one it is dead code hiding the
     *    mechanism; disagreeing — a count that read anything beyond the
     *    entries — it puts the screen and the ledger's record of the
     *    step out of step, and the next walk through the history jumps
     *    back. The run is still walked, because the next one begins
     *    where it ends. */
    for (uint32_t i = 0; i < u->n_signals; i++) {
        at = kaya_parse_value(rec, at, &v);
        at = kaya_parse_value(rec, at, &v);
    }

    /* 2. texts: PAIRS of (I64 widget id, restored Str). EMPTY IN THIS
     *    SCENE and folded anyway: the only step here is the insert and
     *    finishing the form is a separate transaction, so no group of
     *    this app's ever holds a text write. The fold stays because the
     *    draft below is this app's copy of an UNCONTROLLED field, and
     *    restoring an episode is a programmatic write, which never
     *    echoes — the delta is the only notification a restored field
     *    ever sends. guests/c/undo.c is where that run carries
     *    something. */
    for (uint32_t i = 0; i < u->n_texts; i++) {
        at = kaya_parse_value(rec, at, &v);
        at = kaya_parse_value(rec, at, &w);
        if (v.i == (int64_t)W_FIELD)
            str_copy(draft, draft_cap, &w);
    }

    /* 3. entries: ARITY-FIRST groups, so a reader needs no schema —
     *    I64 size (counting itself), collection, flags (bit 0 = the
     *    entry EXISTS), variant, path_len, path_len instance-path keys,
     *    the entry's key, then the record's fields. The arity is what
     *    lets a reader take the fields it models and walk past the rest;
     *    this app models one of the two, `done`, because that is all the
     *    count needs — the title on screen comes from the element
     *    binding and never from here.
     *
     *    A RESTORED ENTRY CARRIES ITS RECORD AND A REMOVED ONE CARRIES
     *    NONE — `size` is 6 + path + fields for the first and 6 + path
     *    for the second — so the fields are read before they are used
     *    and only a present entry has a `done` to fold. */
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
        /* The record's fields, taken BY ARITY rather than guessed at:
         * 5 fixed ints + the path + the key are already read. */
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
     *    path keys, then the instance's keys IN ORDER. Present for
     *    instances whose order the step changed, and "changed the order"
     *    includes an insert or a remove: undoing this scene's add states
     *    the instance's keys as empty and redoing it states them as
     *    {t1}. This app only ever appends, so the run never says
     *    anything the entries run did not already imply — it is folded
     *    because position is the one thing a per-entry statement cannot
     *    carry, and an app that decides that is safe to skip has decided
     *    something about steps it has not written yet. */
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
            /* EACH RESTATED KEY BRINGS ITS OWN `done` WITH IT, looked up
             * in the model the entries run above has already brought up
             * to date. Reordering the keys and leaving the flags where
             * they lay would tick one todo's box on another's row. */
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
    /* THE MINTER, HAND-SPELLED. The eight sugar bindings spell this
     * `insert_fresh` and keep the counter inside the binding
     * (docs/fresh-key-plan.md); the floor takes no sugar, so the counter
     * is here, and the rule that matters is that NOTHING DECREMENTS IT.
     * Undo and redo replay captured keys inside the core and never
     * re-enter this handler — the fold above restores the key an entry
     * already had — so walking the history moves this counter not at
     * all. Counting the model instead would rewind on an undo and hand
     * one name to two todos. */
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
                /* One field's delta: the title never travels. The 0
                 * after F_DONE is the witnessed variant — a record
                 * collection has one constructor. */
                kaya_tx_collection_update_field(&tx, C_TODOS, 0, 0, keys[0],
                                                F_DONE, 0,
                                                kaya_bool(payload.i != 0));
                write_items_left(&tx);
                kaya_submit(tx.buf, tx.len);
            }
        } else if (kaya_parse_click(rec, &id, keys, 2, &n_keys)) {
            if (id == W_ADD && n_keys == 0 && n_todos < MAX_TODOS) {
                /* The empty-draft guard every real form has: nothing to
                 * insert, nothing to command — and NOT an undoable step
                 * either, because an app names the steps a user would
                 * expect back and a refused add is not one. */
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
                /* ONE RECORD, AND IT IS THE WHOLE UNDO SURFACE — AT THE
                 * FRONT OF THE BUFFER. A transaction is a bare list with
                 * no header, so head-of-batch is the one position
                 * per-transaction metadata can occupy unambiguously.
                 * Everything after it is what the step DID: the insert,
                 * and the count the insert changed. The core keeps the
                 * inverse of both. */
                kaya_tx_undo_group(&tx, 0, kaya_str(step));
                kaya_tx_collection_insert(
                    &tx, C_TODOS, 0, 0, kaya_str(todos[n_todos - 1].key), 0,
                    (KayaVal[]){kaya_str(draft), kaya_bool(0)}, 2);
                write_items_left(&tx);
                kaya_submit(tx.buf, tx.len);
                /* FINISHING THE FORM IS NOT PART OF THE STEP. Its own
                 * transaction, so undoing the add does not put the draft
                 * back beside a todo that is gone — and `clear` inside a
                 * group would be REFUSED at apply anyway, because it
                 * destroys widget-owned text the core never held. The
                 * field empties on screen and reports text_changed("")
                 * through its normal edit path, so the branch above
                 * empties the draft; the cursor then lands back in it. */
                uint8_t finish[128];
                KayaTx form = {finish, 0};
                kaya_tx_widget_command(&form, W_FIELD, KAYA_COMMAND_CLEAR);
                kaya_tx_widget_command(&form, W_FIELD, KAYA_COMMAND_FOCUS);
                kaya_submit(form.buf, form.len);
            }
        } else if (parse_undo(rec, KAYA_OCCURRENCE_UNDONE, &undo) ||
                   parse_undo(rec, KAYA_OCCURRENCE_REDONE, &undo)) {
            /* THE FOLD AND NOTHING ELSE, IN BOTH DIRECTIONS. No signal
             * write, no recompute, no transaction: the label the script
             * reads after Edit>Undo and after Edit>Redo is the core's,
             * banked into the add's group by the write_items_left call
             * that rode inside it. What is left for the app is the model
             * the eight bindings would have folded for it, and the two
             * directions want the same fold — a delta says what things
             * now ARE, so undone and redone differ only in which state
             * that is. Registering neither handler is what every sugar
             * todos guest does; this one has a handler only because it
             * has no binding underneath. */
            fold_delta(rec, &undo, draft, sizeof draft);
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
