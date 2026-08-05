/* The undo scene from C, at the explicit wire floor: the undoable step
 * declared as the head-of-batch record it IS, and the undone/redone
 * payload decoded by hand (docs/undo-plan.md D2-D5, §3). Annotated
 * semantics in guests/rust/undo.rs; the byte-frozen contract in
 * tools/scenes/undo.steps.
 *
 * WHAT AN APP WRITES FOR UNDO IS ONE RECORD PER STEP. The sugar
 * languages spell it `tx.undoable("add milk")`; down here it is
 * kaya_tx_undo_group at the FRONT of the buffer, which is what that
 * sugar lowers to and where the wire rule lives — a transaction is a
 * bare list with no header, so head-of-batch is the one position
 * per-transaction metadata can occupy unambiguously. Everything else in
 * the batch is what the step DID, and the core keeps its inverse.
 *
 * THE FIELD'S OWN TYPING UNDO IS THE PLATFORM'S, and this app writes
 * nothing for it. Both tiers arrive through the same Edit>Undo item and
 * kaya decides which answers (D6).
 *
 * THE FLOOR'S HALF OF D5, WHICH THE SUGAR LANGUAGES HIDE. An undo emits
 * exactly one occurrence and it carries the whole restored state — no
 * text_changed for the text it put back, no value_changed for the
 * signals (the echo doctrine: a programmatic write never echoes). In
 * the eight bindings the binding folds that payload into its own mirror
 * before the app's handler runs. C has no binding and no model, so this
 * guest folds it itself, and the fold below IS the documentation of
 * what those eight do: four runs, in order, each self-describing.
 *
 * There is no generated kaya_parse_undone. The generator emits a parse
 * helper per click-shaped and per single-payload occurrence
 * (tools/kaya-bindgen/src/c.rs) and this record is neither, so the floor
 * reads the body — which is the floor being the floor, exactly as it
 * builds its widget tree out of kaya_tx_* calls. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* Guest-allocated ids, counted from 1 per space. The widget numbering
 * follows CREATION order, because that is what the harness addresses:
 * label#0 is the first label created, not the first on screen. */
#define SIG_STATUS 1
#define SIG_HISTORY 2

#define W_COLUMN 1
#define W_STATUS 2  /* label#0 */
#define W_HISTORY 3 /* label#1 */
#define W_FIELD 4   /* entry#0 */
#define W_ADD 5     /* button#0 */
#define W_STAR 6    /* button#1 */
#define W_FOCUS 7   /* button#2 */
#define W_FOR_TODOS 8

#define C_TODOS 1

/* Template nodes: their own id space, never widget ids. */
#define N_ROW 1
#define N_TITLE 2

/* The record's field index: the C floor's "field token". */
#define F_TITLE 0

static void build_scene(void) {
    uint8_t buf[4096];
    KayaTx tx = {buf, 0};

    /* THE GESTURE LAYER, one tier deeper: an app declares the two items
     * and writes nothing else. They act on the focused widget, lower to
     * the platform's own command where it has one, and work out their
     * own enablement from what is focused and what the ledger holds. */
    {
        /* set_window_prop, raw wire: u64 window, u32 wprop, u32 source,
         * value — the packer closes the record without one. */
        size_t start = kaya_wire_begin(&tx, KAYA_TX_SET_WINDOW_PROP);
        kaya_wire_u64(&tx, 0);
        kaya_wire_u32(&tx, KAYA_WPROP_TITLE);
        kaya_wire_u32(&tx, KAYA_SOURCE_CONST);
        kaya_wire_value(&tx, kaya_str("undo"));
        kaya_wire_end(&tx, start);
    }
    /* Menu items live in their OWN id space; the roles are the closed
     * wire vocabulary, hand-spelled at this floor. */
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

    kaya_tx_create_widget(&tx, W_COLUMN, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, W_STATUS, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_STATUS, SIG_STATUS);
    kaya_tx_set_a11y_id(&tx, W_STATUS, "status");
    kaya_tx_create_widget(&tx, W_HISTORY, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_HISTORY, SIG_HISTORY);
    kaya_tx_set_a11y_id(&tx, W_HISTORY, "history");
    kaya_tx_create_widget(&tx, W_FIELD, KAYA_KIND_ENTRY);
    kaya_tx_set_a11y_id(&tx, W_FIELD, "draft");
    kaya_tx_create_widget(&tx, W_ADD, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_ADD, "add");
    kaya_tx_create_widget(&tx, W_STAR, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_STAR, "star");
    /* THE SCENE'S WAY BACK TO THE FIELD. `star` does not move the cursor
     * on its own — an app that reaches for focus after every action is
     * deciding where the user is looking — so the scene says so itself,
     * and the routing question ("what is focused?") stays visible in the
     * script rather than hidden in a handler. */
    kaya_tx_create_widget(&tx, W_FOCUS, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_FOCUS, "focus");

    kaya_tx_create_collection(&tx, C_TODOS,
                              (KayaVariantSchema[]){{(uint32_t[]){KAYA_VALUE_STR}, 1}}, 1);
    kaya_tx_create_for(&tx, W_FOR_TODOS, C_TODOS);
    kaya_tx_create_widget(&tx, N_ROW, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, N_TITLE, KAYA_KIND_LABEL);
    kaya_tx_bind_text_element(&tx, N_TITLE, 0, F_TITLE);
    kaya_tx_add_child(&tx, N_ROW, N_TITLE);
    kaya_tx_template_end(&tx);

    kaya_tx_add_child(&tx, W_COLUMN, W_STATUS);
    kaya_tx_add_child(&tx, W_COLUMN, W_HISTORY);
    kaya_tx_add_child(&tx, W_COLUMN, W_FIELD);
    kaya_tx_add_child(&tx, W_COLUMN, W_ADD);
    kaya_tx_add_child(&tx, W_COLUMN, W_STAR);
    kaya_tx_add_child(&tx, W_COLUMN, W_FOCUS);
    kaya_tx_add_child(&tx, W_COLUMN, W_FOR_TODOS);
    /* THE SCENE TYPES WITH REAL KEYSTROKES, so something has to be
     * holding focus when it does — and focus is the routing question's
     * other half. */
    kaya_tx_widget_command(&tx, W_FIELD, KAYA_COMMAND_FOCUS);
    kaya_tx_mount(&tx, 0, W_COLUMN); /* window 0: the default */

    kaya_submit(tx.buf, tx.len);
}

/* The model, hand-kept per C's no-binding-model decision: the keys of
 * the collection, in order. `total` below is its length. */
#define MAX_TODOS 32
static char todo_keys[MAX_TODOS][16];
static unsigned n_todos = 0;

static int key_index(const KayaVal *key) {
    for (unsigned i = 0; i < n_todos; i++)
        if (key->s_len == strlen(todo_keys[i]) &&
            memcmp(key->s, todo_keys[i], key->s_len) == 0)
            return (int)i;
    return -1;
}

static void key_copy(char *dst, size_t cap, const KayaVal *key) {
    size_t len = key->s_len < cap - 1 ? key->s_len : cap - 1;
    memcpy(dst, key->s, len);
    dst[len] = 0;
}

/* An undone/redone body's fixed head, plus where its delta starts. The
 * shape is spec.rs's `undone`: window, four RUN COUNTS, the label, then
 * one flat value list read as those four runs in order. */
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
    /* The flat list is a counted value sequence: {u32 count, u32
     * reserved, count values}. The counts above already say how the
     * values divide, so the total is skipped rather than trusted. */
    u->at = at + 8;
    return 1;
}

/* Fold one undone/redone payload into this app's own state — the work
 * a binding does for a guest in the other eight languages.
 *
 * A STATEMENT OF THE RESTORED STATE, NOT A REPLAY OF OPS: every group
 * says what a thing now IS, so applying this twice is the same as
 * applying it once, and nothing here re-derives anything. */
static void fold_delta(const uint8_t *rec, const KayaUndo *u, char *draft,
                       size_t draft_cap) {
    size_t at = u->at;
    KayaVal v, w;

    /* 1. signals: PAIRS of (I64 signal id, restored value). NOTHING TO
     *    FOLD, and that is doctrine rather than laziness: a signal's
     *    value at rest is the core's, and every widget bound to it has
     *    already been updated. No binding mirrors signals either. The
     *    run is still walked, because the next one begins where it
     *    ends. */
    for (uint32_t i = 0; i < u->n_signals; i++) {
        at = kaya_parse_value(rec, at, &v);
        at = kaya_parse_value(rec, at, &v);
    }

    /* 2. texts: PAIRS of (I64 widget id, restored Str). THE DELTA IS
     *    THE ONLY NOTIFICATION for this: restoring an episode is a
     *    programmatic write, and a programmatic write never echoes, so
     *    an app that folds text_changed into its own draft — which is
     *    every app, the field being uncontrolled — would go stale on
     *    exactly this step if it ignored the run. */
    for (uint32_t i = 0; i < u->n_texts; i++) {
        at = kaya_parse_value(rec, at, &v);
        at = kaya_parse_value(rec, at, &w);
        if (v.i == (int64_t)W_FIELD) {
            size_t len = w.s_len < draft_cap - 1 ? w.s_len : draft_cap - 1;
            memcpy(draft, w.s, len);
            draft[len] = 0;
        }
    }

    /* 3. entries: ARITY-FIRST groups, so a reader needs no schema —
     *    I64 size (counting itself), collection, flags (bit 0 = the
     *    entry EXISTS), variant, path_len, path_len instance-path keys,
     *    the entry's key, then the record's fields. The size is what
     *    lets this guest skip fields it does not model: the title is
     *    displayed by the element binding, never by the app. */
    for (uint32_t i = 0; i < u->n_entries; i++) {
        KayaVal size, collection, flags, variant, path_len, key;
        at = kaya_parse_value(rec, at, &size);
        at = kaya_parse_value(rec, at, &collection);
        at = kaya_parse_value(rec, at, &flags);
        at = kaya_parse_value(rec, at, &variant);
        at = kaya_parse_value(rec, at, &path_len);
        for (int64_t k = 0; k < path_len.i; k++)
            at = kaya_parse_value(rec, at, &v);
        at = kaya_parse_value(rec, at, &key);
        int index = key_index(&key);
        if (flags.i & 1) {
            if (index < 0 && n_todos < MAX_TODOS) {
                key_copy(todo_keys[n_todos], sizeof todo_keys[0], &key);
                n_todos += 1;
            }
        } else if (index >= 0) {
            for (unsigned k = (unsigned)index + 1; k < n_todos; k++)
                memcpy(todo_keys[k - 1], todo_keys[k], sizeof todo_keys[0]);
            n_todos -= 1;
        }
        /* The record's fields, skipped BY ARITY rather than guessed at:
         * 5 fixed ints + the path + the key are already read. */
        for (int64_t k = 6 + path_len.i; k < size.i; k++)
            at = kaya_parse_value(rec, at, &v);
    }

    /* 4. orders: ARITY-FIRST likewise — I64 size, collection, path_len,
     *    path keys, then the instance's keys IN ORDER. Present for
     *    instances whose order the step changed, because position is
     *    the one thing per-entry statements cannot carry.
     *
     *    AND "CHANGED THE ORDER" INCLUDES AN INSERT OR A REMOVE, which
     *    is worth saying because it is easy to read this run as the
     *    move-only one and skip it: measured, EVERY group delta in this
     *    scene carries an order run (undoing `add milk` states the
     *    instance's keys as empty, redoing it states them as {t1}). An
     *    app that walked past this run would still be correct here only
     *    because the entries run above says the same thing a second
     *    way — and that is this scene's accident, not a rule. */
    for (uint32_t i = 0; i < u->n_orders; i++) {
        KayaVal size, collection, path_len, key;
        at = kaya_parse_value(rec, at, &size);
        at = kaya_parse_value(rec, at, &collection);
        at = kaya_parse_value(rec, at, &path_len);
        for (int64_t k = 0; k < path_len.i; k++)
            at = kaya_parse_value(rec, at, &v);
        char restated[MAX_TODOS][16];
        unsigned n = 0;
        for (int64_t k = 3 + path_len.i; k < size.i; k++) {
            at = kaya_parse_value(rec, at, &key);
            if (n < MAX_TODOS)
                key_copy(restated[n++], sizeof restated[0], &key);
        }
        /* A top-level instance is this app's whole list (path_len 0). */
        if (path_len.i == 0) {
            memcpy(todo_keys, restated, sizeof restated[0] * n);
            n_todos = n;
        }
    }
}

/* What the history label says a step was. A typing episode has no
 * authored name and kaya invents none ("Undo Typing" is an Apple
 * convention, not a scene string), so the empty label is the app's to
 * spell. The label points into the record and is not NUL-terminated. */
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
    /* The fold: widget-owned state arrives as occurrences; the app's
     * copy is this buffer, not a widget read. `next_key` is monotonic
     * and is NOT the count — an undone insert frees no key, because ids
     * are never reused. */
    char draft[128] = "";
    unsigned next_key = 0;
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
        uint8_t buf[512];
        char status[192];
        KayaUndo undo;
        if (kaya_parse_text_changed(rec, &id, keys, 2, &n_keys, &text)) {
            if (id == W_FIELD && n_keys == 0) {
                unsigned len = text.s_len < sizeof draft - 1
                    ? text.s_len : (unsigned)sizeof draft - 1;
                memcpy(draft, text.s, len);
                draft[len] = 0;
            }
        } else if (kaya_parse_click(rec, &id, keys, 2, &n_keys)) {
            if (n_keys != 0)
                continue;
            if (id == W_ADD) {
                KayaTx tx = {buf, 0};
                /* The empty-draft guard every real form has — and NOT an
                 * undoable step: an app names the steps a user would
                 * expect back, and a refused add is not one. */
                if (draft[0] == '\0') {
                    snprintf(status, sizeof status, "nothing to add, %u total",
                             n_todos);
                    kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str(status));
                    kaya_submit(tx.buf, tx.len);
                    continue;
                }
                next_key += 1;
                char step[160], key[16];
                snprintf(step, sizeof step, "add %s", draft);
                snprintf(key, sizeof key, "t%u", next_key);
                /* ONE RECORD, AND IT IS THE WHOLE UNDO SURFACE — AT THE
                 * FRONT OF THE BUFFER. The name is what the step is
                 * called; everything after it in this batch is what the
                 * step did. */
                kaya_tx_undo_group(&tx, 0, kaya_str(step));
                kaya_tx_collection_insert(&tx, C_TODOS, 0, 0, kaya_str(key), 0,
                                          (KayaVal[]){kaya_str(draft)}, 1);
                if (n_todos < MAX_TODOS) {
                    snprintf(todo_keys[n_todos], sizeof todo_keys[0], "%s", key);
                    n_todos += 1;
                }
                snprintf(status, sizeof status, "added %s, %u total", draft,
                         n_todos);
                kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str(status));
                /* A PURE EFFECT rides along and is simply not restored:
                 * undo restores state, not where you were looking. */
                kaya_tx_widget_command(&tx, W_FIELD, KAYA_COMMAND_FOCUS);
                kaya_submit(tx.buf, tx.len);
                /* FINISHING THE FORM IS NOT PART OF THE STEP. Its own
                 * transaction, so undoing the add does not put the draft
                 * back beside a todo that is gone — and `clear` inside a
                 * group would be REFUSED at apply anyway, because it
                 * destroys widget-owned text the core never held. The
                 * field empties on screen and reports text_changed("")
                 * through its normal edit path, so the fold above empties
                 * the draft. */
                uint8_t finish[64];
                KayaTx form = {finish, 0};
                kaya_tx_widget_command(&form, W_FIELD, KAYA_COMMAND_CLEAR);
                kaya_submit(form.buf, form.len);
            } else if (id == W_STAR) {
                /* A group at its smallest: one signal write, which is
                 * the undoable set's whole vocabulary on the reactive
                 * side. */
                KayaTx tx = {buf, 0};
                kaya_tx_undo_group(&tx, 0, kaya_str("star"));
                kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str("starred"));
                kaya_submit(tx.buf, tx.len);
            } else if (id == W_FOCUS) {
                KayaTx tx = {buf, 0};
                kaya_tx_widget_command(&tx, W_FIELD, KAYA_COMMAND_FOCUS);
                kaya_submit(tx.buf, tx.len);
            }
        } else if (parse_undo(rec, KAYA_OCCURRENCE_UNDONE, &undo)) {
            /* Per window, and PERSISTENT: a history is walked as often
             * as the user likes, so nothing here unregisters. The fold
             * runs BEFORE the transaction is built, because the record's
             * bytes are the core's and live only until the next call. */
            char name[128];
            const char *step = what(&undo.label, name, sizeof name);
            fold_delta(rec, &undo, draft, sizeof draft);
            KayaTx tx = {buf, 0};
            snprintf(status, sizeof status, "undid %s, %u total", step, n_todos);
            kaya_tx_write_signal(&tx, SIG_HISTORY, kaya_str(status));
            kaya_submit(tx.buf, tx.len);
        } else if (parse_undo(rec, KAYA_OCCURRENCE_REDONE, &undo)) {
            char name[128];
            const char *step = what(&undo.label, name, sizeof name);
            fold_delta(rec, &undo, draft, sizeof draft);
            KayaTx tx = {buf, 0};
            snprintf(status, sizeof status, "redid %s, %u total", step, n_todos);
            kaya_tx_write_signal(&tx, SIG_HISTORY, kaya_str(status));
            kaya_submit(tx.buf, tx.len);
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
