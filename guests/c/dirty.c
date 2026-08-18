/* The dirty-state scene from C, at the explicit wire floor: unsaved work
 * is SET_WINDOW_PROP carrying KAYA_WPROP_DIRTY and a Bool, and the
 * veto/confirm flow around it is assembled by hand out of two
 * occurrences the generator emits no parser for (docs/dirty-plan.md
 * D1-D5). Annotated semantics in guests/rust/dirty.rs; the byte-frozen
 * contract in tools/scenes/dirty.steps.
 *
 * DECLARED, NEVER INFERRED: the edit handler writes the document signal
 * AND says dirty(true); neither implies the other, and kaya watches no
 * signals. The mark ARMS NOTHING (D3) — the veto class below is composed
 * of parts that predate it. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* Guest-allocated ids, counted from 1 per space. CREATION ORDER IS
 * CONTRACT: the script says label#0/label#1 and button#0/button#1, so
 * the doc label precedes the status label and `edit` precedes `save`.
 * Swapping either pair reads the wrong widget rather than failing. */
#define SIG_DOC 1
#define SIG_STATUS 2

#define W_COLUMN 1
#define W_DOC 2    /* label#0 */
#define W_STATUS 3 /* label#1 */
#define W_EDIT 4   /* button#0 */
#define W_SAVE 5   /* button#1 */

/* A Bool window prop, packed by hand: the generated
 * kaya_tx_set_window_prop closes the record BEFORE the value. One
 * function for both booleans — veto_close and dirty are orthogonal and
 * differ by a constant. */
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

    /* The title: the same record with a Str value. Titles are
     * byte-compared across platforms, so the dirty mark never goes in
     * the title string — the chrome diverges, the string may not. */
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
    /* `dirty` IS DELIBERATELY NOT SET HERE: the script reads the clean
     * window first, and that assertion is the one a write-only lowering
     * cannot pass. */

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

/* The veto class's first half: the user asked a veto_close window to
 * close and NOTHING HAS CLOSED. Header, then the window id, and that id
 * is the whole record — no correlation token, the core waits for no
 * response. The app matches on the window so a second window's close
 * cannot fall into this app's one dialog. */
static int parse_close_requested(const uint8_t *rec, uint64_t *window) {
    const KayaRecordHeader *h = (const KayaRecordHeader *)rec;
    if (h->kind != KAYA_OCCURRENCE_CLOSE_REQUESTED)
        return 0;
    memcpy(window, rec + sizeof(KayaRecordHeader), 8);
    return 1;
}

/* The second half: the alert's one answer. Header, the alert id, then a
 * u32 choice — an action INDEX (0 or 1), or KAYA_ALERT_CHOICE_CANCEL for
 * every platform-native dismissal alike (Esc, back, a tap outside, the
 * cancel button). The trailing u32 is reserved and unread. The dialog is
 * already gone when this arrives and the id retires here. */
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
    /* The alert-id counter the eight bindings keep inside `show_alert`
     * (crates/kaya/src/app.rs), hand-spelled. `live` is this app's
     * registration: the id says WHICH question was answered, and zero
     * means nothing is being asked. */
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
                /* Three statements in one transaction, none of them
                 * derived from another. */
                KayaTx tx = {buf, 0};
                kaya_tx_write_signal(&tx, SIG_DOC, kaya_str("notes and a line"));
                kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str("unsaved"));
                window_bool(&tx, 0, KAYA_WPROP_DIRTY, 1);
                kaya_submit(tx.buf, tx.len);
            } else if (id == W_SAVE) {
                /* The mark coming DOWN is the half of the lowering a
                 * backend that only ever sets the flag never reaches. */
                KayaTx tx = {buf, 0};
                kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str("saved"));
                window_bool(&tx, 0, KAYA_WPROP_DIRTY, 0);
                kaya_submit(tx.buf, tx.len);
            }
        } else if (parse_close_requested(rec, &id)) {
            if (id != 0)
                continue;
            alerts += 1;
            live = alerts;
            KayaTx tx = {buf, 0};
            /* One record for the whole dialog: window, id, HOW MANY of
             * the two action slots are real, and five Str values.
             * `actions` is 1 here, so action1 rides empty and is
             * ignored. The cancel slot is always present, because every
             * native dismissal has to resolve to something. */
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
                /* Kept: the mark STAYS UP, because answering a dialog is
                 * not saving. Touching no prop here is what the script's
                 * last assertion reads. */
                kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str("kept editing"));
            } else {
                /* THIS ARM ABORTS IF IT EVER RUNS: destroy_window(0) on
                 * the primary window is refused, so an app can veto a
                 * close but cannot agree to one (docs/traps.md). The
                 * scene answers cancel instead. */
                kaya_tx_destroy_window(&tx, 0);
            }
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
