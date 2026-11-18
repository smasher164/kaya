/* The restored shape (tools/scenes/restoredocs.steps;
 * docs/restoration-plan.md SR9) on the C floor: each document's title and
 * text live in its own session scope, and act two recreates the documents
 * the last launch left, takes each scope back, and selects the active one. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>

#define SCOPE_DOCUMENT 2
#define MAX_DOCS 8

#define SIG_CAPTION 1 /* + the document's index */
#define W_BODY 1      /* each document's widgets: W_BODY + 10 * index + k */

static uint64_t docs[MAX_DOCS];
static size_t n_docs;
static char titles[MAX_DOCS][64];

static void scope_get(uint64_t doc, const char *key, const char *def, char *out, size_t cap) {
    size_t len = 0;
    if (kaya_session_get_string(SCOPE_DOCUMENT, doc, (const uint8_t *)key, strlen(key), (uint8_t *)out,
                                cap - 1, &len) == 0)
        len = (size_t)snprintf(out, cap, "%s", def);
    out[len < cap ? len : cap - 1] = 0;
}

static void scope_set(uint64_t doc, const char *key, const char *value, size_t len) {
    kaya_session_set_string(SCOPE_DOCUMENT, doc, (const uint8_t *)key, strlen(key), (const uint8_t *)value, len);
}

static void document_title(KayaTx *tx, uint64_t document, const char *title) {
    size_t start = kaya_wire_begin(tx, KAYA_TX_SET_DOCUMENT_PROP);
    kaya_wire_u64(tx, document);
    kaya_wire_u32(tx, KAYA_DPROP_TITLE);
    kaya_wire_u32(tx, KAYA_SOURCE_CONST);
    kaya_wire_value(tx, kaya_str(title));
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

static void build_scene(void) {
    uint8_t buf[8192];
    KayaTx tx = {buf, 0, sizeof buf};
    uint64_t active = 0;

    n_docs = 0;
    for (uint32_t i = 0; i < kaya_session_window_count(); i++) {
        uint64_t window = 0, act = 0;
        int64_t n = kaya_session_window(i, &window, &act, NULL, NULL, docs, MAX_DOCS);
        if (n >= 0 && window == 0) {
            n_docs = (size_t)n < MAX_DOCS ? (size_t)n : MAX_DOCS;
            active = act;
        }
    }
    if (n_docs == 0) {
        static const char *const FIRST[] = {"a", "b", "c"};
        for (size_t i = 0; i < 3; i++) {
            docs[i] = 10 + i;
            scope_set(docs[i], "title", FIRST[i], 1);
        }
        n_docs = 3;
    }

    window_prop(&tx, KAYA_WPROP_TITLE, kaya_str("restoredocs"));
    window_prop(&tx, KAYA_WPROP_WIDTH, kaya_f64(640));
    window_prop(&tx, KAYA_WPROP_HEIGHT, kaya_f64(420));
    for (size_t i = 0; i < n_docs; i++) {
        uint64_t doc = docs[i], base = W_BODY + 10 * i;
        char text[256];
        scope_get(doc, "title", "untitled", titles[i], sizeof titles[i]);
        kaya_tx_add_document(&tx, 0, doc);
        document_title(&tx, doc, titles[i]);
        kaya_session_restore(SCOPE_DOCUMENT, doc, doc);
        snprintf(text, sizeof text, "%s body", titles[i]);
        kaya_tx_create_signal(&tx, SIG_CAPTION + i, kaya_str(text));
        kaya_tx_create_widget(&tx, base, KAYA_KIND_COLUMN);
        kaya_tx_create_widget(&tx, base + 1, KAYA_KIND_LABEL);
        kaya_tx_bind_text(&tx, base + 1, SIG_CAPTION + i);
        snprintf(text, sizeof text, "caption-%s", titles[i]);
        kaya_tx_set_a11y_id(&tx, base + 1, text);
        kaya_tx_create_widget(&tx, base + 2, KAYA_KIND_ENTRY);
        snprintf(text, sizeof text, "body-%s", titles[i]);
        kaya_tx_set_a11y_id(&tx, base + 2, text);
        scope_get(doc, "body", "", text, sizeof text);
        kaya_tx_set_text(&tx, base + 2, text);
        kaya_tx_create_widget(&tx, base + 3, KAYA_KIND_BUTTON);
        kaya_tx_set_text(&tx, base + 3, "recall");
        snprintf(text, sizeof text, "recall-%s", titles[i]);
        kaya_tx_set_a11y_id(&tx, base + 3, text);
        kaya_tx_add_child(&tx, base, base + 1);
        kaya_tx_add_child(&tx, base, base + 2);
        kaya_tx_add_child(&tx, base, base + 3);
        kaya_tx_mount(&tx, doc, base);
    }
    if (active != 0)
        kaya_tx_select_document(&tx, active);
    kaya_submit(tx.buf, tx.len);
}

static void *app(void *arg) {
    (void)arg;
    build_scene();
    const uint8_t *rec;
    for (;;) {
        size_t size = kaya_next_occurrence(&rec);
        if (size == 0)
            break; /* shutdown */
        if (size == KAYA_OCCURRENCE_WOKEN)
            continue;
        uint64_t id;
        KayaVal keys[2], payload;
        uint32_t n_keys;
        if (kaya_parse_text_changed(rec, &id, keys, 2, &n_keys, &payload)) {
            for (size_t i = 0; i < n_docs; i++)
                if (id == W_BODY + 10 * i + 2)
                    scope_set(docs[i], "body", payload.s, payload.s_len);
        } else if (kaya_parse_click(rec, &id, keys, 2, &n_keys)) {
            for (size_t i = 0; i < n_docs; i++) {
                if (id != W_BODY + 10 * i + 3)
                    continue;
                char now[64], text[96];
                uint8_t buf[256];
                KayaTx tx = {buf, 0, sizeof buf};
                scope_get(docs[i], "title", "untitled", now, sizeof now);
                snprintf(text, sizeof text, "%s body", now);
                kaya_tx_write_signal(&tx, SIG_CAPTION + i, kaya_str(text));
                kaya_submit(tx.buf, tx.len);
            }
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
