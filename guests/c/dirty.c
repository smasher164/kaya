/* The dirty-state scene from C, at the explicit wire floor: unsaved work
 * declared as the window-prop record it IS, and the veto/confirm flow
 * around it assembled by hand out of two occurrences the generator emits
 * no parser for (docs/dirty-plan.md D1-D5). Annotated semantics in
 * guests/rust/dirty.rs; the byte-frozen contract in
 * tools/scenes/dirty.steps.
 *
 * WHAT AN APP WRITES FOR UNSAVED WORK IS ONE BOOLEAN. The sugar
 * languages spell it `tx.window(0).dirty(true)`; down here it is
 * SET_WINDOW_PROP carrying KAYA_WPROP_DIRTY and a Bool — the SAME record
 * that carries the title a few lines above it and veto_close one line
 * below, which is what "one boolean beside title and veto_close" (D1)
 * means once you can see the wire.
 *
 * AND THE APP NEVER SPELLS CHROME. The dot in macOS's close button, the
 * leading `*` in a Windows caption and the bullet in a GTK header bar are
 * three backends' answers to this one record, and nothing in this file
 * can tell which one it is talking to. The phones answer with no chrome
 * at all, because they have none to show (D4) — the prop still applies
 * and still reads back there; it simply lowers to nothing.
 *
 * THE TITLE STRING IS NOT WHERE IT GOES. Qt's `[*]` placeholder inside
 * the app's own title is the named rejection (D1): kaya's scene titles
 * are byte-compared across platforms, so the declared string has to stay
 * identical everywhere while the chrome diverges. The title record below
 * writes `dirty`, and nothing in this file ever rewrites it.
 *
 * DECLARED, NEVER INFERRED. The edit handler writes the document signal
 * AND says dirty(true), in one transaction; neither implies the other.
 * kaya does not watch your signals — "the document has unsaved changes"
 * is a claim only the app can make, and a binding that inferred it from a
 * write would be answering a question the app owns. Saving says the
 * other half, which is what makes the mark come DOWN as well as up.
 *
 * AND THE MARK ARMS NOTHING (D3). Everything below the handlers is the
 * veto class, composed out of parts that predate this prop: veto_close
 * turns the user's close into a QUESTION, the app answers by showing its
 * own alert, and the alert's result decides. No part of it is dirty's
 * doing — an app that wanted no dialog would set the prop and stop. The
 * floor is where that is legible, because the sugar languages hide both
 * halves behind a handler registration and this file has to name them.
 *
 * THE TWO RECORDS ARE READ BY HAND, for the reason the undone/redone
 * body is: kaya-bindgen emits a parse helper per click-shaped and per
 * single-payload occurrence (tools/kaya-bindgen/src/c.rs), and
 * close_requested and alert_result are neither — fixed fields, no
 * payload — so this guest decodes their bodies the way it packs its own. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* Guest-allocated ids, counted from 1 per space.
 *
 * THE ORDER BELOW IS CONTRACT, not layout taste: the harness addresses
 * widgets by CREATION order within a kind, so the doc label is created
 * before the status label and `edit` before `save` because the script
 * says label#0/label#1 and button#0/button#1. Swapping either pair would
 * not fail with "no such target" — it would read the wrong widget and
 * compare the wrong string. */
#define SIG_DOC 1
#define SIG_STATUS 2

#define W_COLUMN 1
#define W_DOC 2    /* label#0 */
#define W_STATUS 3 /* label#1 */
#define W_EDIT 4   /* button#0 */
#define W_SAVE 5   /* button#1 */

/* A BOOL WINDOW PROP, PACKED OUT: {u64 window, u32 prop, u32 source,
 * value}. The generated kaya_tx_set_window_prop closes the record BEFORE
 * the value — the tail convention it shares with SET_PROPERTY — so a
 * caller with a value to write begins the record itself, which is what
 * every C guest's title already does (guests/c/undo.c).
 *
 * ONE FUNCTION FOR BOTH BOOLEANS, deliberately: veto_close and dirty
 * differ by a constant and by nothing else. They are ORTHOGONAL — either
 * can be set without the other, on every platform — and this window takes
 * both because it is an editor: it owns its close so that it can ask. */
static void window_bool(KayaTx *tx, uint64_t window, uint32_t prop, int on) {
    size_t start = kaya_wire_begin(tx, KAYA_TX_SET_WINDOW_PROP);
    kaya_wire_u64(tx, window);
    kaya_wire_u32(tx, prop);
    kaya_wire_u32(tx, KAYA_SOURCE_CONST);
    kaya_wire_value(tx, kaya_bool(on));
    kaya_wire_end(tx, start);
}

static void build_scene(void) {
    uint8_t buf[1024];
    KayaTx tx = {buf, 0};

    /* The title: the same record with a Str value, so the two spellings
     * sit next to each other. `dirty` is the scene's name and this prop
     * never touches it — on any backend, in either direction. */
    {
        size_t start = kaya_wire_begin(&tx, KAYA_TX_SET_WINDOW_PROP);
        kaya_wire_u64(&tx, 0);
        kaya_wire_u32(&tx, KAYA_WPROP_TITLE);
        kaya_wire_u32(&tx, KAYA_SOURCE_CONST);
        kaya_wire_value(&tx, kaya_str("dirty"));
        kaya_wire_end(&tx, start);
    }
    /* The veto, set at BUILD: a window that opts in after the user has
     * already reached for the close button opted in too late. */
    window_bool(&tx, 0, KAYA_WPROP_VETO_CLOSE, 1);
    /* AND `dirty` IS NOT SET HERE. Its default false is the script's
     * first reading of the chrome, and that assertion is the one a
     * write-only lowering cannot pass: a backend that reported an
     * unmarked window as dirty would sail through every step this scene
     * takes after the edit. The clean window has to be seen first. */

    kaya_tx_create_signal(&tx, SIG_DOC, kaya_str("notes"));
    kaya_tx_create_signal(&tx, SIG_STATUS, kaya_str("saved"));

    kaya_tx_create_widget(&tx, W_COLUMN, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, W_DOC, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_DOC, SIG_DOC);
    kaya_tx_create_widget(&tx, W_STATUS, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_STATUS, SIG_STATUS);
    kaya_tx_create_widget(&tx, W_EDIT, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_EDIT, "edit");
    kaya_tx_create_widget(&tx, W_SAVE, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_SAVE, "save");

    kaya_tx_add_child(&tx, W_COLUMN, W_DOC);
    kaya_tx_add_child(&tx, W_COLUMN, W_STATUS);
    kaya_tx_add_child(&tx, W_COLUMN, W_EDIT);
    kaya_tx_add_child(&tx, W_COLUMN, W_SAVE);
    kaya_tx_mount(&tx, 0, W_COLUMN); /* window 0: the default */

    kaya_submit(tx.buf, tx.len);
}

/* THE VETO CLASS'S FIRST HALF: the user asked a veto_close window to
 * close and NOTHING HAS CLOSED. The body is the header this file already
 * packs — {u32 size, u16 kind, u16 flags} — then the window id, and that
 * id is the whole record: there is no correlation token, because there is
 * no response the core is waiting for.
 *
 * THE APP MATCHES ON THE WINDOW, which is the floor's spelling of a rule
 * the sugar languages get from their shape: a handler registered against
 * a window can only ever mean that surface's close. Down here the record
 * carries the id and the reader has to say which surface it answers for,
 * so a second window's close cannot fall into this app's one dialog. */
static int parse_close_requested(const uint8_t *rec, uint64_t *window) {
    const KayaRecordHeader *h = (const KayaRecordHeader *)rec;
    if (h->kind != KAYA_OCCURRENCE_CLOSE_REQUESTED)
        return 0;
    memcpy(window, rec + sizeof(KayaRecordHeader), 8);
    return 1;
}

/* THE SECOND HALF: the alert's one answer. Header, the alert id, then a
 * u32 choice — an action INDEX (0 or 1), or KAYA_ALERT_CHOICE_CANCEL for
 * every platform-native dismissal alike (Esc, back, a tap outside, the
 * cancel button itself), which is why an app never has to enumerate the
 * ways a dialog can go away. The trailing u32 is reserved and unread. The
 * dialog is already gone when this arrives and the id retires here. */
static int parse_alert_result(const uint8_t *rec, uint64_t *alert,
                              uint32_t *choice) {
    const KayaRecordHeader *h = (const KayaRecordHeader *)rec;
    if (h->kind != KAYA_OCCURRENCE_ALERT_RESULT)
        return 0;
    size_t at = sizeof(KayaRecordHeader);
    memcpy(alert, rec + at, 8);
    at += 8;
    memcpy(choice, rec + at, 4);
    return 1;
}

static void *app(void *arg) {
    (void)arg;
    build_scene();
    /* THE MINTER, HAND-SPELLED, and its rule stated where a contract is
     * legible. The eight bindings allocate an alert id inside
     * `show_alert` from a counter that starts at 1 (crates/kaya/src/
     * app.rs), hand it back, and register the app's handler against it;
     * the floor takes no sugar (invariant 5), so the counter is here.
     *
     * `live` IS THAT REGISTRATION. An id retires when its result fires
     * and one alert may be live per process, so an app that showed two
     * would still get exactly one result at a time — but it is the id
     * that says WHICH question was answered, and an app that answered a
     * result it did not ask for would be composing someone else's flow
     * into its own. Zero means nothing is being asked. */
    uint64_t alerts = 0, live = 0;
    const uint8_t *rec;
    for (;;) {
        size_t size = kaya_next_occurrence(&rec);
        if (size == 0)
            break; /* shutdown */
        if (size == KAYA_OCCURRENCE_WOKEN)
            continue; /* no record; rec is NULL */
        uint64_t id;
        KayaVal keys[2];
        uint32_t n_keys, choice;
        uint8_t buf[512];
        if (kaya_parse_click(rec, &id, keys, 2, &n_keys)) {
            if (n_keys != 0)
                continue;
            if (id == W_EDIT) {
                /* THE COMPOSITION THIS SCENE EXISTS TO SHOW, in one
                 * transaction: what the document now says, what the app
                 * calls that, and the fact that it is unsaved. Three
                 * statements, none of them derived from another. */
                KayaTx tx = {buf, 0};
                kaya_tx_write_signal(&tx, SIG_DOC, kaya_str("notes and a line"));
                kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str("unsaved"));
                window_bool(&tx, 0, KAYA_WPROP_DIRTY, 1);
                kaya_submit(tx.buf, tx.len);
            } else if (id == W_SAVE) {
                /* The same act in reverse, and this app's whole notion of
                 * saving: a real editor would write a file here and mark
                 * the window clean on the way back. The mark coming down
                 * is the half of the lowering that a backend which only
                 * ever SETS the flag never reaches. */
                KayaTx tx = {buf, 0};
                kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str("saved"));
                window_bool(&tx, 0, KAYA_WPROP_DIRTY, 0);
                kaya_submit(tx.buf, tx.len);
            }
        } else if (parse_close_requested(rec, &id)) {
            /* Nothing has closed: the veto class says so, and this app
             * answers a question rather than reporting a fact. An editor
             * with unsaved work asks; a clean one would agree at once by
             * submitting destroy_window right here, with no dialog. */
            if (id != 0)
                continue;
            alerts += 1;
            live = alerts;
            KayaTx tx = {buf, 0};
            /* ONE RECORD FOR THE WHOLE DIALOG: the window it belongs to,
             * the id, HOW MANY of the two action slots are real, and five
             * Str values. `actions` is 1 here, so action1 rides empty and
             * is ignored — the slots are fixed because the platform floor
             * is (ContentDialog's three are two actions plus close), and
             * the cancel slot is always present because every native
             * dismissal has to resolve to something. */
            kaya_tx_show_alert(&tx, 0, live, 1, kaya_str("unsaved changes"),
                               kaya_str("the document has unsaved changes"),
                               kaya_str("Discard"), kaya_str(""),
                               kaya_str("Keep Editing"));
            kaya_submit(tx.buf, tx.len);
        } else if (parse_alert_result(rec, &id, &choice)) {
            if (id != live)
                continue;
            live = 0;
            KayaTx tx = {buf, 0};
            if (choice == KAYA_ALERT_CHOICE_CANCEL) {
                /* Kept: the window stays AND THE MARK STAYS UP, because
                 * answering a dialog is not saving. Nothing here touches
                 * the prop, and that omission is the assertion the script
                 * ends on. */
                kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str("kept editing"));
            } else {
                /* Agreed — any action index, this dialog having one. The
                 * app closes the window ITSELF: the core never closed it,
                 * which is the whole content of the veto class. For the
                 * PRIMARY window that ends the process, so the scene
                 * answers cancel instead and this arm stays the honest
                 * spelling of "yes, close it" rather than a step. */
                kaya_tx_destroy_window(&tx, 0);
            }
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
