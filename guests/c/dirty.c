/* The dirty-state scene (tools/scenes/dirty.steps).
 * DECLARED, NEVER INFERRED: kaya watches no signals. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* Guest-allocated ids (tools/check-c-ids.py). CREATION ORDER IS CONTRACT:
 * swapping a pair reads the wrong widget rather than failing. */
#define SIG_DOC 1
#define SIG_STATUS 2

#define W_COLUMN 1
#define W_DOC 2    /* label#0 */
#define W_STATUS 3 /* label#1 */
#define W_EDIT 4   /* button#0 */
#define W_SAVE 5   /* button#1 */

/* Packed by hand: the generated setter closes the record BEFORE the value. */
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
    KayaTx tx = {buf, 0, sizeof buf};

    /* Titles are byte-compared, so the mark never goes in the string. */
    {
        size_t start = kaya_wire_begin(&tx, KAYA_TX_SET_WINDOW_PROP);
        kaya_wire_u64(&tx, 0);
        kaya_wire_u32(&tx, KAYA_WPROP_TITLE);
        kaya_wire_u32(&tx, KAYA_SOURCE_CONST);
        kaya_wire_value(&tx, kaya_str("dirty"));
        kaya_wire_end(&tx, start);
    }
    /* Set at BUILD: opting in after the user reaches for close is too late. */
    window_bool(&tx, 0, KAYA_WPROP_VETO_CLOSE, 1);
    /* `dirty` IS DELIBERATELY NOT SET HERE: the script reads clean first. */

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

/* The window id is the whole record: the core waits for no response. */
static int parse_close_requested(const uint8_t *rec, uint64_t *window) {
    const KayaRecordHeader *h = (const KayaRecordHeader *)rec;
    if (h->kind != KAYA_OCCURRENCE_CLOSE_REQUESTED)
        return 0;
    memcpy(window, rec + sizeof(KayaRecordHeader), 8);
    return 1;
}

/* Header, alert id, u32 choice (crates/kaya/src/spec.rs); the trailing
 * u32 is reserved and unread. */
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
    /* The alert-id counter the bindings hide; `live` 0 means nothing asked. */
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
                KayaTx tx = {buf, 0, sizeof buf};
                kaya_tx_write_signal(&tx, SIG_DOC, kaya_str("notes and a line"));
                kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str("unsaved"));
                window_bool(&tx, 0, KAYA_WPROP_DIRTY, 1);
                kaya_submit(tx.buf, tx.len);
            } else if (id == W_SAVE) {
                KayaTx tx = {buf, 0, sizeof buf};
                kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str("saved"));
                window_bool(&tx, 0, KAYA_WPROP_DIRTY, 0);
                kaya_submit(tx.buf, tx.len);
            }
        } else if (parse_close_requested(rec, &id)) {
            if (id != 0)
                continue;
            alerts += 1;
            live = alerts;
            KayaTx tx = {buf, 0, sizeof buf};
            /* One record: the count says how many action slots are real,
             * the unused ones ride empty. */
            kaya_tx_show_alert(&tx, 0, live, 1, kaya_str("unsaved changes"),
                               kaya_str("the document has unsaved changes"),
                               kaya_str("Discard"), kaya_str(""),
                               kaya_str("Keep Editing"));
            kaya_submit(tx.buf, tx.len);
        } else if (parse_alert_result(rec, &id, &choice)) {
            if (id != live)
                continue;
            live = 0;
            KayaTx tx = {buf, 0, sizeof buf};
            if (choice == KAYA_ALERT_CHOICE_CANCEL) {
                /* The mark STAYS UP: touching no prop is the assertion. */
                kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str("kept editing"));
            } else {
                /* ABORTS IF IT EVER RUNS — docs/traps.md, "An app can VETO
                 * a close but cannot AGREE to one". */
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
