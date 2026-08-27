/* The entry scene from C, on the function floor: the uncontrolled
 * contract end to end. The field owns its text, the app folds
 * text_changed into `draft`, and the clear's own text_changed("")
 * re-enters through that fold. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* Guest-allocated ids. WIDGETS AND TEMPLATE NODES SHARE ONE SPACE, so the
 * N_ run continues the W_ one; signals and collections each count from 1
 * in their own (DESIGN.md, Binding conventions). */
#define SIG_STATUS 1
#define W_COLUMN 1
#define W_FIELD 2
#define W_ADD 3
#define W_STATUS 4
#define W_FOR_TODOS 5
#define C_TODOS 1
#define N_TODO_LABEL 6

static void build_scene(void) {
    uint8_t buf[1024];
    KayaTx tx = {buf, 0, sizeof buf};

    kaya_tx_create_signal(&tx, SIG_STATUS, kaya_str("no todos"));
    kaya_tx_create_widget(&tx, W_COLUMN, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, W_FIELD, KAYA_KIND_ENTRY);
    kaya_tx_create_widget(&tx, W_ADD, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_ADD, "add");
    kaya_tx_create_widget(&tx, W_STATUS, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_STATUS, SIG_STATUS);

    kaya_tx_create_collection(&tx, C_TODOS,
                              (KayaVariantSchema[]){{(uint32_t[]){KAYA_VALUE_STR}, 1}}, 1);
    kaya_tx_create_for(&tx, W_FOR_TODOS, C_TODOS);
    kaya_tx_create_widget(&tx, N_TODO_LABEL, KAYA_KIND_LABEL);
    kaya_tx_bind_text_element(&tx, N_TODO_LABEL, 0, 0);
    kaya_tx_template_end(&tx);

    kaya_tx_add_child(&tx, W_COLUMN, W_FIELD);
    kaya_tx_add_child(&tx, W_COLUMN, W_ADD);
    kaya_tx_add_child(&tx, W_COLUMN, W_STATUS);
    kaya_tx_add_child(&tx, W_COLUMN, W_FOR_TODOS);
    kaya_tx_mount(&tx, 0, W_COLUMN); /* window 0: the default */

    kaya_submit(tx.buf, tx.len);
}

static void *app(void *arg) {
    (void)arg;
    build_scene();
    /* Widget-owned state arrives as occurrences: the app's copy is this
     * buffer, never a widget read. */
    char draft[128] = "";
    unsigned total = 0;
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
        if (kaya_parse_text_changed(rec, &id, keys, 2, &n_keys, &text)) {
            if (id == W_FIELD && n_keys == 0) {
                unsigned len = text.s_len < sizeof draft - 1
                    ? text.s_len : (unsigned)sizeof draft - 1;
                memcpy(draft, text.s, len);
                draft[len] = 0;
            }
        } else if (kaya_parse_click(rec, &id, keys, 2, &n_keys)) {
            if (id == W_ADD && n_keys == 0) {
                uint8_t buf[512];
                KayaTx tx = {buf, 0, sizeof buf};
                char status[192];
                if (draft[0] == '\0') {
                    snprintf(status, sizeof status, "nothing to add, %u total",
                             total);
                    kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str(status));
                    kaya_submit(tx.buf, tx.len);
                    continue;
                }
                total += 1;
                char key[16];
                snprintf(key, sizeof key, "t%u", total);
                kaya_tx_collection_insert(&tx, C_TODOS, 0, 0, kaya_str(key), 0,
                                          (KayaVal[]){kaya_str(draft)}, 1);
                snprintf(status, sizeof status, "added %s, %u total", draft,
                         total);
                kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str(status));
                kaya_tx_widget_command(&tx, W_FIELD, KAYA_COMMAND_CLEAR);
                kaya_tx_widget_command(&tx, W_FIELD, KAYA_COMMAND_FOCUS);
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
