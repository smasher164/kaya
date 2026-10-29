/* The document-tabs scene (tools/scenes/doctabs.steps; docs/doctabs-plan.md
 * §5) on the C floor: three documents, one armed against a close, a shared
 * region beside them, the "+", and a programmatic select that echoes
 * nothing. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* Surface ids (documents, regions) and widget ids are separate namespaces;
 * both are guest-allocated (tools/check-c-ids.py). */
#define DOC_A 10
#define DOC_B 11
#define DOC_C 12
#define REGION_NOTES 30

#define SIG_STATUS 1
#define SIG_CAPTION 2 /* + the document's index; a new one's is 100 + n */

#define W_BODY 1 /* each document's widgets: W_BODY + 10 * index + k */
#define W_REGION 100 /* each region's widgets: W_REGION + 10 * n + k */
#define W_UNTITLED 500 /* each new document's: W_UNTITLED + 10 * n + k */

static const char *const NAMES[] = {"a", "b", "c"};

/* Packed by hand: the generated setter closes the record BEFORE the value. */
static void document_prop(KayaTx *tx, uint64_t document, uint32_t prop, KayaVal value) {
    size_t start = kaya_wire_begin(tx, KAYA_TX_SET_DOCUMENT_PROP);
    kaya_wire_u64(tx, document);
    kaya_wire_u32(tx, prop);
    kaya_wire_u32(tx, KAYA_SOURCE_CONST);
    kaya_wire_value(tx, value);
    kaya_wire_end(tx, start);
}

static void window_prop(KayaTx *tx, uint32_t prop, KayaVal value) {
    size_t start = kaya_wire_begin(tx, KAYA_TX_SET_WINDOW_PROP);
    kaya_wire_u64(tx, 0);
    kaya_wire_u32(tx, prop);
    kaya_wire_u32(tx, KAYA_SOURCE_CONST);
    kaya_wire_value(tx, value);
    kaya_wire_end(tx, start);
}

/* THE ONE BUILDER every window's shared region comes from, the first
 * window's and a torn-out one's alike (docs/doctabs-plan.md §1.2). */
static uint64_t first_buttons[16];
static void region(KayaTx *tx, uint64_t window, uint64_t id, uint64_t n) {
    uint64_t base = W_REGION + 10 * n;
    kaya_tx_add_region(tx, window, id, KAYA_REGION_EDGE_LEADING);
    kaya_tx_create_widget(tx, base, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(tx, base + 1, KAYA_KIND_LABEL);
    kaya_tx_bind_text(tx, base + 1, SIG_STATUS);
    kaya_tx_set_a11y_id(tx, base + 1, "status");
    kaya_tx_create_widget(tx, base + 2, KAYA_KIND_ENTRY);
    kaya_tx_set_a11y_id(tx, base + 2, "note");
    kaya_tx_create_widget(tx, base + 3, KAYA_KIND_BUTTON);
    kaya_tx_set_text(tx, base + 3, "to a");
    kaya_tx_set_a11y_id(tx, base + 3, "first");
    kaya_tx_add_child(tx, base, base + 1);
    kaya_tx_add_child(tx, base, base + 2);
    kaya_tx_add_child(tx, base, base + 3);
    kaya_tx_mount(tx, id, base);
    if (n < 16)
        first_buttons[n] = base + 3;
}

static void build_scene(void) {
    uint8_t buf[8192];
    KayaTx tx = {buf, 0, sizeof buf};

    window_prop(&tx, KAYA_WPROP_TITLE, kaya_str("doctabs"));
    window_prop(&tx, KAYA_WPROP_WIDTH, kaya_f64(640));
    window_prop(&tx, KAYA_WPROP_HEIGHT, kaya_f64(420));
    window_prop(&tx, KAYA_WPROP_NEW_DOCUMENT, kaya_bool(1));
    kaya_tx_create_signal(&tx, SIG_STATUS, kaya_str("ready"));

    for (uint64_t i = 0; i < 3; i++) {
        uint64_t doc = DOC_A + i, base = W_BODY + 10 * i;
        char text[64];
        kaya_tx_add_document(&tx, 0, doc);
        document_prop(&tx, doc, KAYA_DPROP_TITLE, kaya_str(NAMES[i]));
        snprintf(text, sizeof text, "/documents/%s", NAMES[i]);
        document_prop(&tx, doc, KAYA_DPROP_TOOLTIP, kaya_str(text));
        snprintf(text, sizeof text, "%s body", NAMES[i]);
        kaya_tx_create_signal(&tx, SIG_CAPTION + i, kaya_str(text));
        kaya_tx_create_widget(&tx, base, KAYA_KIND_COLUMN);
        kaya_tx_create_widget(&tx, base + 1, KAYA_KIND_LABEL);
        kaya_tx_bind_text(&tx, base + 1, SIG_CAPTION + i);
        snprintf(text, sizeof text, "body-%s", NAMES[i]);
        kaya_tx_set_a11y_id(&tx, base + 1, text);
        kaya_tx_create_widget(&tx, base + 2, KAYA_KIND_ENTRY);
        snprintf(text, sizeof text, "field-%s", NAMES[i]);
        kaya_tx_set_a11y_id(&tx, base + 2, text);
        kaya_tx_add_child(&tx, base, base + 1);
        kaya_tx_add_child(&tx, base, base + 2);
        if (doc == DOC_B) {
            kaya_tx_create_widget(&tx, base + 3, KAYA_KIND_BUTTON);
            kaya_tx_set_text(&tx, base + 3, "mark b");
            kaya_tx_set_a11y_id(&tx, base + 3, "mark");
            kaya_tx_add_child(&tx, base, base + 3);
        }
        kaya_tx_mount(&tx, doc, base);
    }
    document_prop(&tx, DOC_B, KAYA_DPROP_INTERCEPT_CLOSE, kaya_bool(1));
    region(&tx, 0, REGION_NOTES, 0);

    kaya_submit(tx.buf, tx.len);
}

/* The record's fields after the header, in spec order (crates/kaya/src/spec.rs). */
static int occurrence(const uint8_t *rec, uint16_t kind) {
    return ((const KayaRecordHeader *)rec)->kind == kind;
}

static uint64_t u64_at(const uint8_t *rec, size_t at) {
    uint64_t v;
    memcpy(&v, rec + sizeof(KayaRecordHeader) + at, 8);
    return v;
}

static uint32_t u32_at(const uint8_t *rec, size_t at) {
    uint32_t v;
    memcpy(&v, rec + sizeof(KayaRecordHeader) + at, 4);
    return v;
}

static const char *name_of(uint64_t doc) {
    return doc >= DOC_A && doc <= DOC_C ? NAMES[doc - DOC_A] : "untitled";
}

static void status(const char *text) {
    uint8_t buf[256];
    KayaTx tx = {buf, 0, sizeof buf};
    kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str(text));
    kaya_submit(tx.buf, tx.len);
}

static void *app(void *arg) {
    (void)arg;
    build_scene();
    uint64_t alerts = 0, live = 0, untitled = 0, regions = 0;
    const uint8_t *rec;
    for (;;) {
        size_t size = kaya_next_occurrence(&rec);
        if (size == 0)
            break; /* shutdown */
        if (size == KAYA_OCCURRENCE_WOKEN)
            continue; /* no record; rec is NULL */
        uint64_t id;
        KayaVal keys[2];
        uint32_t n_keys;
        uint8_t buf[4096];
        char text[128];
        if (kaya_parse_click(rec, &id, keys, 2, &n_keys)) {
            if (n_keys != 0)
                continue;
            int first = 0;
            for (uint64_t n = 0; n <= regions && n < 16; n++)
                first |= first_buttons[n] == id;
            KayaTx tx = {buf, 0, sizeof buf};
            if (first) {
                /* Programmatic: no document_selected follows. */
                kaya_tx_select_document(&tx, DOC_A);
            } else if (id == W_BODY + 10 + 3) {
                document_prop(&tx, DOC_B, KAYA_DPROP_DIRTY, kaya_bool(1));
                kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str("marked b"));
            }
            kaya_submit(tx.buf, tx.len);
        } else if (occurrence(rec, KAYA_OCCURRENCE_DOCUMENT_SELECTED)) {
            snprintf(text, sizeof text, "selected %s", name_of(u64_at(rec, 8)));
            status(text);
        } else if (occurrence(rec, KAYA_OCCURRENCE_DOCUMENT_CLOSED)) {
            snprintf(text, sizeof text, "closed %s", name_of(u64_at(rec, 0)));
            status(text);
        } else if (occurrence(rec, KAYA_OCCURRENCE_DOCUMENT_MOVED)) {
            snprintf(text, sizeof text, "moved %s to %u", name_of(u64_at(rec, 0)), u32_at(rec, 16));
            status(text);
        } else if (occurrence(rec, KAYA_OCCURRENCE_DOCUMENTS_CLOSE_REQUESTED)) {
            snprintf(text, sizeof text, "asked about %u", u32_at(rec, 8));
            status(text);
        } else if (occurrence(rec, KAYA_OCCURRENCE_NEW_DOCUMENT_REQUESTED)) {
            untitled += 1;
            uint64_t doc = 100 + untitled, base = W_UNTITLED + 10 * untitled;
            KayaTx tx = {buf, 0, sizeof buf};
            snprintf(text, sizeof text, "untitled %llu", (unsigned long long)untitled);
            kaya_tx_add_document(&tx, 0, doc);
            document_prop(&tx, doc, KAYA_DPROP_TITLE, kaya_str(text));
            kaya_tx_select_document(&tx, doc);
            char caption[64];
            snprintf(caption, sizeof caption, "%s body", text);
            kaya_tx_create_signal(&tx, SIG_CAPTION + 100 + untitled, kaya_str(caption));
            kaya_tx_create_widget(&tx, base, KAYA_KIND_COLUMN);
            kaya_tx_create_widget(&tx, base + 1, KAYA_KIND_LABEL);
            kaya_tx_bind_text(&tx, base + 1, SIG_CAPTION + 100 + untitled);
            kaya_tx_add_child(&tx, base, base + 1);
            kaya_tx_mount(&tx, doc, base);
            char said[64];
            snprintf(said, sizeof said, "new %s", text);
            kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str(said));
            kaya_submit(tx.buf, tx.len);
        } else if (occurrence(rec, KAYA_OCCURRENCE_DOCUMENTS_DETACHED)) {
            /* source u64, window u64, then a run of I64 values: the documents. */
            uint64_t window = u64_at(rec, 8);
            uint32_t count = u32_at(rec, 16);
            regions += 1;
            KayaTx tx = {buf, 0, sizeof buf};
            region(&tx, window, 300 + regions, regions);
            size_t len = (size_t)snprintf(text, sizeof text, "detached");
            for (uint32_t i = 0; i < count && len < sizeof text; i++) {
                uint64_t doc = u64_at(rec, 24 + 16 * (size_t)i + 8);
                len += (size_t)snprintf(text + len, sizeof text - len, " %s", name_of(doc));
            }
            kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str(text));
            kaya_submit(tx.buf, tx.len);
        } else if (occurrence(rec, KAYA_OCCURRENCE_DOCUMENT_CLOSE_REQUESTED)) {
            if (u64_at(rec, 0) != DOC_B)
                continue;
            alerts += 1;
            live = alerts;
            KayaTx tx = {buf, 0, sizeof buf};
            kaya_tx_show_alert(&tx, 0, live, 1, kaya_str("unsaved changes"),
                               kaya_str("b has unsaved changes"), kaya_str("Discard"),
                               kaya_str(""), kaya_str("Keep Editing"));
            kaya_submit(tx.buf, tx.len);
        } else if (occurrence(rec, KAYA_OCCURRENCE_ALERT_RESULT)) {
            if (u64_at(rec, 0) != live)
                continue;
            live = 0;
            KayaTx tx = {buf, 0, sizeof buf};
            if (u32_at(rec, 8) == KAYA_ALERT_CHOICE_CANCEL) {
                kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str("kept b"));
            } else {
                kaya_tx_close_document(&tx, DOC_B);
                kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str("discarded b"));
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
