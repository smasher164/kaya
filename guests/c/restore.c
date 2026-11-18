/* The restoration scene (tools/scenes/restore.steps;
 * docs/restoration-plan.md SR15) on the C floor: the draft lives in the
 * session store and comes back through the ordinary build; the list's
 * scroll and the text's caret come back on their own. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* WIDGETS AND TEMPLATE NODES SHARE ONE SPACE (tools/check-c-ids.py). */
#define W_ROOT 1
#define W_LAUNCH 2
#define W_FIELD 3
#define W_BAR 4
#define W_JUMP 5
#define W_SELECT 6
#define W_DOC 7
#define W_SCROLL 8
#define W_FOR 9
#define N_LINE 10
#define C_MESSAGES 1
#define SIG_LAUNCH 1

#define SCOPE_APP 0

static void build_scene(void) {
    static uint8_t buf[16384];
    KayaTx tx = {buf, 0, sizeof buf};
    static const char *const LAUNCH[] = {"launch fresh", "launch resumed", "launch recovered"};
    uint32_t launch = kaya_session_restored();
    char draft[256];
    size_t len = 0;
    if (kaya_session_get_string(SCOPE_APP, 0, (const uint8_t *)"draft", 5, (uint8_t *)draft, sizeof draft - 1,
                                &len) == 0)
        len = 0;
    draft[len < sizeof draft ? len : sizeof draft - 1] = 0;

    {
        size_t start = kaya_wire_begin(&tx, KAYA_TX_SET_WINDOW_PROP);
        kaya_wire_u64(&tx, 0);
        kaya_wire_u32(&tx, KAYA_WPROP_TITLE);
        kaya_wire_u32(&tx, KAYA_SOURCE_CONST);
        kaya_wire_value(&tx, kaya_str("restore"));
        kaya_wire_end(&tx, start);
    }
    kaya_tx_create_signal(&tx, SIG_LAUNCH, kaya_str(LAUNCH[launch < 3 ? launch : 0]));
    kaya_tx_create_widget(&tx, W_ROOT, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, W_LAUNCH, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_LAUNCH, SIG_LAUNCH);
    kaya_tx_create_widget(&tx, W_FIELD, KAYA_KIND_ENTRY);
    kaya_tx_set_text(&tx, W_FIELD, draft);
    kaya_tx_create_widget(&tx, W_BAR, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, W_JUMP, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_JUMP, "jump");
    kaya_tx_set_a11y_id(&tx, W_JUMP, "jump");
    kaya_tx_create_widget(&tx, W_SELECT, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_SELECT, "select");
    kaya_tx_set_a11y_id(&tx, W_SELECT, "select");
    kaya_tx_add_child(&tx, W_BAR, W_JUMP);
    kaya_tx_add_child(&tx, W_BAR, W_SELECT);
    kaya_tx_create_widget(&tx, W_DOC, KAYA_KIND_TEXTAREA);
    kaya_tx_set_a11y_id(&tx, W_DOC, "doc");
    kaya_tx_set_text(&tx, W_DOC, "the quick brown fox");
    kaya_tx_create_widget(&tx, W_SCROLL, KAYA_KIND_SCROLL);
    kaya_tx_set_a11y_id(&tx, W_SCROLL, "list");
    kaya_tx_set_grow(&tx, W_SCROLL, 1.0);

    kaya_tx_create_collection(&tx, C_MESSAGES, (KayaVariantSchema[]){{(uint32_t[]){KAYA_VALUE_STR}, 1}}, 1);
    kaya_tx_create_for(&tx, W_FOR, C_MESSAGES);
    kaya_tx_create_widget(&tx, N_LINE, KAYA_KIND_LABEL);
    kaya_tx_bind_text_element(&tx, N_LINE, 0, 0);
    kaya_tx_template_end(&tx);
    kaya_tx_set_a11y_id(&tx, W_FOR, "messages");
    kaya_tx_add_child(&tx, W_SCROLL, W_FOR);

    kaya_tx_add_child(&tx, W_ROOT, W_LAUNCH);
    kaya_tx_add_child(&tx, W_ROOT, W_FIELD);
    kaya_tx_add_child(&tx, W_ROOT, W_BAR);
    kaya_tx_add_child(&tx, W_ROOT, W_DOC);
    kaya_tx_add_child(&tx, W_ROOT, W_SCROLL);
    kaya_tx_mount(&tx, 0, W_ROOT);

    for (int i = 1; i <= 60; i++) {
        char key[16], text[32];
        snprintf(key, sizeof key, "m%d", i);
        snprintf(text, sizeof text, "message %d", i);
        kaya_tx_collection_insert(&tx, C_MESSAGES, 0, 0, kaya_str(key), 0, (KayaVal[]){kaya_str(text)}, 1);
    }
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
        uint8_t buf[256];
        KayaTx tx = {buf, 0, sizeof buf};
        if (kaya_parse_text_changed(rec, &id, keys, 2, &n_keys, &payload)) {
            if (id == W_FIELD)
                kaya_session_set_string(SCOPE_APP, 0, (const uint8_t *)"draft", 5, (const uint8_t *)payload.s,
                                        payload.s_len);
        } else if (kaya_parse_click(rec, &id, keys, 2, &n_keys)) {
            if (id == W_JUMP)
                kaya_tx_scroll_to_row(&tx, W_FOR, kaya_str("m30"));
            else if (id == W_SELECT)
                kaya_tx_select_range(&tx, W_DOC, 4, 9);
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
