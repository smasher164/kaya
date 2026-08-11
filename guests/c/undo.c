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
 * AND THE APP NAMES NO TODO. A todo is a title and nothing else — it
 * has no identity of its own — so the key is AUTHORED AT INSERT rather
 * than chosen. The eight sugar bindings spell that `insert_fresh` and
 * keep the counter inside the binding (docs/fresh-key-plan.md); the
 * floor takes no sugar (invariant 5), so this guest hand-mints the same
 * I64 sequence and writes the contract out beside the counter, which is
 * the floor's job — the explicit tier is where a contract is legible.
 *
 * LABEL#2 IS THIS APP'S COLLECTION MIRROR, RENDERED: the keys it holds,
 * in the order it holds them. It is where the script reads the two
 * things a count cannot see — an undone REMOVE comes back under its
 * ORIGINAL key at its ORIGINAL position, and a key minted after a
 * history walk is still fresh. Down here that mirror is this file's own
 * arrays, folded by hand out of the delta's entries and orders runs,
 * which is exactly the work the other eight bindings do before their
 * guest's handler runs.
 *
 * AND LABEL#3 IS THE SAME IDEA ONE LEVEL DOWN: what the user has typed
 * into the ROWS, by key. Every other step in this scene is about the
 * draft — a live widget whose id this app allocated — but a collection
 * row's field has no id an app could hold; its identity is (template
 * node, key path), the pair its clicks and its edits already arrive
 * under. That is why the payload's texts run is now an ARITY-FIRST
 * group like its entries and orders siblings, and the decode below
 * narrates the shape value by value. A fixed pair of (widget id, text)
 * had nowhere to put the path, so a row's typing could not be named to
 * the app and was therefore not banked at all (docs/undo-plan.md §3b).
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
 * label#0 is the first label created, not the first on screen.
 *
 * SO THE ORDER BELOW IS CONTRACT, not layout taste. The keys label is
 * created THIRD and the notes label FOURTH, before the draft entry,
 * because the script says label#2 and label#3; a scene that created
 * either anywhere else would not fail with "no such target" — the index
 * would resolve to the first STAMPED row label and the assertion would
 * read a todo's title.
 *
 * AND label#3 IS INDEX-STABLE FOR THE WHOLE RUN even though this scene
 * destroys row copies: nothing created before it is ever destroyed, so
 * it does not matter whether a backend prunes its harness registries on
 * Destroy (the SwiftUI interpreter does not). The row ENTRY the script
 * reads is addressed `entry#last` for the other half of that fact. */
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

/* Template nodes: their own id space, never widget ids. A node id and a
 * widget id may collide as NUMBERS (N_NOTE is 3, so is W_HISTORY) and
 * nothing is wrong: an occurrence's identity is the PAIR (id, key path),
 * and a live widget's path is empty while a stamped copy's never is. The
 * handlers below match on both halves for exactly that reason. */
#define N_ROW 1
#define N_TITLE 2
#define N_NOTE 3

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
    /* THE SCENE'S WAY BACK TO THE FIELD. `star` does not move the cursor
     * on its own — an app that reaches for focus after every action is
     * deciding where the user is looking — so the scene says so itself,
     * and the routing question ("what is focused?") stays visible in the
     * script rather than hidden in a handler. */
    kaya_tx_create_widget(&tx, W_FOCUS, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_FOCUS, "focus");
    /* THE STEP WHOSE INVERSE IS AN IDENTITY. Every other step in this
     * scene restores CONTENT; this one restores an ENTRY, and an entry
     * is a key — the core captured it and the instance's order before
     * the removal, so the app remembers neither. */
    kaya_tx_create_widget(&tx, W_REMOVE, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_REMOVE, "remove");

    kaya_tx_create_collection(&tx, C_TODOS,
                              (KayaVariantSchema[]){{(uint32_t[]){KAYA_VALUE_STR}, 1}}, 1);
    kaya_tx_create_for(&tx, W_FOR_TODOS, C_TODOS);
    kaya_tx_create_widget(&tx, N_ROW, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, N_TITLE, KAYA_KIND_LABEL);
    kaya_tx_bind_text_element(&tx, N_TITLE, 0, F_TITLE);
    kaya_tx_add_child(&tx, N_ROW, N_TITLE);
    /* THE ROW'S OWN FIELD, and the reason this scene grew. A copy's text
     * edits are the same occurrence the draft's are, one identity deeper
     * — (node, key path) instead of a widget id — and the ledger banks
     * them the same way now that the payload can NAME them. It is
     * created after the title, so the row reads title-then-field.
     *
     * NOTHING BINDS IT, and this comment used to explain that the sugar
     * languages therefore spelled it with the widget-kind floor here too
     * — the template tier's sugar took a SOURCE for the text, and an
     * unbound field had none. That was true when it was written and it
     * was the wrong lesson to draw: what it described was a HOLE in the
     * template zone, not a property of unbound fields. The zone had
     * constructors for three kinds where the live zone had fourteen, so
     * every guest that wanted an entry inside a collection reached for
     * the floor and this file recorded the workaround as the rule. The
     * text editor's find bar did the same thing months later, and the
     * question "don't we have entry sugar?" is what finally read this
     * paragraph back (docs/sugar-pass-plan.md).
     *
     * The sugar languages now spell it `t.entry()` — the unbound form,
     * which is exactly this case — and seed a copy from its row with
     * `entry_bound(src)` when they want that instead. Down here neither
     * distinction exists: every widget in this file is a create_widget,
     * which is the floor's usual relationship to sugar. */
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
    /* THE SCENE TYPES WITH REAL KEYSTROKES, so something has to be
     * holding focus when it does — and focus is the routing question's
     * other half. */
    kaya_tx_widget_command(&tx, W_FIELD, KAYA_COMMAND_FOCUS);
    kaya_tx_mount(&tx, 0, W_COLUMN); /* window 0: the default */

    kaya_submit(tx.buf, tx.len);
}

/* The model, hand-kept per C's no-binding-model decision: the keys of
 * the collection, in order, and each entry's title beside it. `total`
 * below is its length.
 *
 * THE TITLES ARE NEW AND THEY ARE NOT DECORATION. The rows on screen
 * still get their text from the element binding, never from here — but
 * the remove names its target ("remove milk", "removed milk, 1 total")
 * and takes it from the app's OWN model, so the app has to know what it
 * is removing. In the eight sugar bindings the mirror holds whole
 * records and this costs nothing; down here it is one more array. */
#define MAX_TODOS 32
#define MAX_TITLE 128
static int64_t todo_keys[MAX_TODOS];
static char todo_titles[MAX_TODOS][MAX_TITLE];
static unsigned n_todos = 0;

/* The SECOND mirror of widget-owned text, and the one this slice is
 * about: what has been typed into the ROWS, by key.
 *
 * THE DRAFT AND A ROW'S FIELD ARE THE SAME KIND OF THING — an
 * uncontrolled entry whose text the app learns from occurrences — and
 * they need two mirrors only because a row's field has no id an app
 * could hold. Its identity is (template node, key path), so the key is
 * what indexes this map, exactly as it indexes `todo_keys` above.
 *
 * Kept sorted ASCENDING by key, because label#3 renders it in that
 * order (the contract in tools/scenes/undo.steps) and the floor sorts
 * where the invariant lives — at the insert — rather than at every
 * render. */
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

/* A value's bytes into a NUL-terminated buffer: the wire's strings point
 * into the record and are not terminated. */
static void str_copy(char *dst, size_t cap, const KayaVal *v) {
    size_t len = v->s_len < cap - 1 ? v->s_len : cap - 1;
    memcpy(dst, v->s, len);
    dst[len] = 0;
}

/* label#2: the mirror above, rendered — "no keys", or "keys" and the
 * I64 keys in order, decimal, comma-separated. */
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

/* ONE RULE FOR A NOTE, WRITTEN ONCE, and both of its arrival paths call
 * it: the row's own edit occurrence, and the texts run of an
 * undone/redone payload restoring that same field. Two spellings of
 * "what a note is" would let the script's assertion pass through the
 * wrong one.
 *
 * AN EMPTY NOTE IS NO NOTE — an empty text REMOVES the key rather than
 * holding it with an empty string — and that is what makes the undo in
 * the script falsifiable: the restore of a row's field to "" has to
 * leave `no notes` behind, so an app that walked past the run reads its
 * stale note back out and fails there. */
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

/* label#3: the notes mirror, rendered — "no notes", or "notes " and
 * `key=text` per note, keys ascending, comma-separated. */
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
    KayaVal v;

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

    /* 2. texts: ARITY-FIRST groups, like the entries and orders runs
     *    below and for the same reason — a group has to carry a PATH,
     *    and a path has no fixed length.
     *
     *        I64 size    counting itself: 3 + path_len + 1
     *        I64 id      a widget id when path_len is 0, a TEMPLATE
     *                    NODE id when it is not
     *        I64 path_len
     *        path_len    values: the copy's key path, outermost first
     *        Str text    the restored text
     *
     *    (crates/kaya/src/wire.rs `undo_bodies_round_trip` pins these
     *    values one by one; this decode is written against that table.)
     *
     *    THE TWO IDENTITIES ARE THE WHOLE POINT OF THE SHAPE. A live
     *    widget is named by an id the app itself allocated — W_FIELD
     *    below, the draft. A stamped copy's field was never allocated by
     *    anyone: it is named the way its clicks and its edits are
     *    already named, by (template node, key path), and for a
     *    top-level For that path is one key — the todo's own. A fixed
     *    pair of (id, text) had nowhere to put the path, so a row's
     *    typing could not be named to the app and was therefore not
     *    banked at all.
     *
     *    AND THE TAIL IS READ BY ARITY, not by counting on there being
     *    exactly one value after the path: `size` says where the group
     *    ends, so a reader that models the text and nothing else walks
     *    past anything the group grows later without a schema. That is
     *    the same discipline the entries run states below.
     *
     *    THE DELTA IS THE ONLY NOTIFICATION for every one of these:
     *    restoring an episode is a programmatic write, and a
     *    programmatic write never echoes, so an app that folds
     *    text_changed into its own mirrors — which is every app, these
     *    fields being uncontrolled — would go stale on exactly this step
     *    if it ignored the run. Which is why ALL of it is walked and not
     *    just its last group: one step can restore the draft and a row's
     *    note, and each entry says which. */
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
            /* The draft. The floor names the widget it models rather
             * than taking any live field's text on trust — this app has
             * one, and an app with two would need the id to tell them
             * apart exactly as the path tells the rows apart. */
            if (id.i == (int64_t)W_FIELD) {
                size_t len = text.s_len < draft_cap - 1 ? text.s_len : draft_cap - 1;
                memcpy(draft, text.s, len);
                draft[len] = 0;
            }
        } else {
            note_set(row, &text);
        }
    }

    /* 3. entries: ARITY-FIRST groups, so a reader needs no schema —
     *    I64 size (counting itself), collection, flags (bit 0 = the
     *    entry EXISTS), variant, path_len, path_len instance-path keys,
     *    the entry's key, then the record's fields. The arity is what
     *    lets a reader take the fields it models and walk past the rest
     *    without a schema; this app models exactly one, the title, and
     *    reads it by index (F_TITLE) out of that run.
     *
     *    A RESTORED ENTRY CARRIES ITS RECORD AND A REMOVED ONE CARRIES
     *    NONE — `size` is 6 + path + fields for the first and 6 + path
     *    for the second — so the fields are read before they are used
     *    and only a present entry has a title to fold. */
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
        /* The record's fields, taken BY ARITY rather than guessed at:
         * 5 fixed ints + the path + the key are already read. */
        for (int64_t k = 6 + path_len.i; k < size.i; k++) {
            at = kaya_parse_value(rec, at, &v);
            if (k - (6 + path_len.i) == F_TITLE)
                title = v;
        }
        int index = key_index(key.i);
        if (flags.i & 1) {
            /* THE KEY IS THE ONE THE ENTRY ALREADY HAD — the core kept
             * it, so nothing here mints and the counter in `app` below
             * never hears about a history walk. */
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
     *    path keys, then the instance's keys IN ORDER. Present for
     *    instances whose order the step changed, because position is
     *    the one thing per-entry statements cannot carry.
     *
     *    AND "CHANGED THE ORDER" INCLUDES AN INSERT OR A REMOVE, which
     *    is worth saying because it is easy to read this run as the
     *    move-only one and skip it: measured, EVERY group delta in this
     *    scene carries an order run (undoing `add milk` states the
     *    instance's keys as empty, redoing it states them as {1}).
     *
     *    AND ONE STEP IN THIS SCENE NEEDS IT OUTRIGHT: undoing the
     *    remove restores an entry that was FIRST, and the entries run
     *    can only say it exists again — position is exactly what a
     *    per-entry statement cannot carry. An app that folds entries and
     *    walks past this run reads "keys 2,1" where the script wants
     *    "keys 1,2". */
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
        /* A top-level instance is this app's whole list (path_len 0).
         *
         * THE TITLES TRAVEL WITH THEIR KEYS. This run states positions
         * and nothing else, so each restated key's title is looked up in
         * the model the entries run above has already brought up to date
         * — reordering the keys and leaving the titles where they lay
         * would deal milk's title to tea's row. */
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
     * copy is this buffer, not a widget read. */
    char draft[128] = "";
    /* THE MINTER, HAND-SPELLED. One counter per collection INSTANCE,
     * and this app has one instance of one collection.
     *
     * The eight sugar bindings spell this `insert_fresh(collection,
     * record)`: the binding owns the counter, mints the key at the
     * insert and hands it back, so no app writes a name for data that
     * has none. The floor takes no sugar (invariant 5), so what that
     * sugar lowers to is written out here (docs/fresh-key-plan.md):
     *
     *   - the counter starts at 0 and a mint is counter+1; the minted
     *     key is an I64;
     *   - ABSORPTION — an explicit I64 key >= the counter carries the
     *     counter past it, applied on the ONE path every insert travels,
     *     which is what makes minted and hand-chosen keys safe to mix.
     *     This app passes no explicit key, so there is nothing here for
     *     the rule to absorb; it is stated because the floor is where a
     *     contract is legible, not because this file exercises it;
     *   - NOTHING DECREMENTS IT. Undo and redo replay captured keys
     *     inside the core and never re-enter this handler — the fold
     *     above restores the key an entry already had — so walking the
     *     history moves no counter and a fresh key is fresh forever.
     *
     * That last rule is the one this file used to leave to luck: the
     * counter was `next_key`, it named todos "t1" and "t2", and an undo
     * that rewound it would have handed one name to two todos. The
     * script now reads the answer out loud (label#2). */
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
        /* Wide enough for every label this app writes in one transaction,
         * the notes list included, because the floor sizes its buffers
         * rather than growing them. */
        uint8_t buf[8192];
        char status[192];
        /* Wide enough for MAX_TODOS I64 keys spelled out, and for as
         * many `key=text` notes. */
        char keys_text[768];
        char notes_text[MAX_NOTES * (MAX_TITLE + 24)];
        KayaUndo undo;
        if (kaya_parse_text_changed(rec, &id, keys, 2, &n_keys, &text)) {
            /* THE TWO FIELDS, TOLD APART BY THE PATH — the identity rule
             * the delta's texts run states, arriving here first. An
             * empty path is a live widget and its id is this app's own;
             * a path names a stamped copy and its id is a template
             * node. */
            if (id == W_FIELD && n_keys == 0) {
                unsigned len = text.s_len < sizeof draft - 1
                    ? text.s_len : (unsigned)sizeof draft - 1;
                memcpy(draft, text.s, len);
                draft[len] = 0;
            } else if (id == N_NOTE && n_keys > 0) {
                /* The row's edit, folded by the SAME rule the restore of
                 * this field will use — one `note_set`, two arrival
                 * paths. Its own transaction, and NOT an undoable one:
                 * the typing is the step, the app's rendering of it is
                 * not, and a group here would bank a second step for
                 * every keystroke. */
                note_set(keys[0].i, &text);
                KayaTx tx = {buf, 0};
                note_list(notes_text, sizeof notes_text);
                kaya_tx_write_signal(&tx, SIG_NOTES, kaya_str(notes_text));
                kaya_submit(tx.buf, tx.len);
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
                /* THE MINT: counter+1, and the key crosses the wire as
                 * an I64 exactly the way an explicit key would. */
                fresh += 1;
                int64_t key = fresh;
                char step[160];
                snprintf(step, sizeof step, "add %s", draft);
                /* ONE RECORD, AND IT IS THE WHOLE UNDO SURFACE — AT THE
                 * FRONT OF THE BUFFER. The name is what the step is
                 * called; everything after it in this batch is what the
                 * step did. */
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
            } else if (id == W_REMOVE) {
                /* THE MODEL'S OWN ANSWER, NEVER A WIDGET'S. The handler
                 * asks its own mirror which entry is FIRST, so an undo
                 * that put the entry back at the end would be visible:
                 * the one that comes back has to come back BEFORE the
                 * one that stayed, and label#2 says which. */
                KayaTx tx = {buf, 0};
                if (n_todos == 0) {
                    /* The empty-collection refusal, the add's twin — not
                     * a step either, and not exercised by the script. */
                    snprintf(status, sizeof status, "nothing to remove, %u total",
                             n_todos);
                    kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str(status));
                    kaya_submit(tx.buf, tx.len);
                    continue;
                }
                char step[160], title[MAX_TITLE];
                snprintf(title, sizeof title, "%s", todo_titles[0]);
                snprintf(step, sizeof step, "remove %s", title);
                /* THE APP REMEMBERS NEITHER THE KEY NOR THE POSITION:
                 * the core captured the entry and the instance's order
                 * before the removal, and hands both back in the delta
                 * (the entries and orders runs of the fold above). */
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
            /* ONE TRANSACTION WITH THE LABEL ABOVE, deliberately: the
             * script reads the history label first, so by the time it
             * reads this one the app's own answer is on screen — not the
             * value the core restored on its way past, which a bare
             * `expect label#2` could otherwise match. The notes ride the
             * same transaction for the same reason, and label#3 is where
             * a walked-past texts run is READ: the core restored the
             * row's field either way, so only the app's own map can say
             * whether the app heard about it. */
            key_list(keys_text, sizeof keys_text);
            kaya_tx_write_signal(&tx, SIG_KEYS, kaya_str(keys_text));
            note_list(notes_text, sizeof notes_text);
            kaya_tx_write_signal(&tx, SIG_NOTES, kaya_str(notes_text));
            kaya_submit(tx.buf, tx.len);
        } else if (parse_undo(rec, KAYA_OCCURRENCE_REDONE, &undo)) {
            char name[128];
            const char *step = what(&undo.label, name, sizeof name);
            fold_delta(rec, &undo, draft, sizeof draft);
            KayaTx tx = {buf, 0};
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
