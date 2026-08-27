/* The stamped-accessibility scene from C, on the function floor: a11y
 * id and label sourced from the row's own value, plus a second
 * collection whose prototype carries a stamped inset and role
 * (docs/tpl-props-plan.md).
 *
 * expect_ax resolves its target by the authored identifier and REFUSES
 * an ambiguous one, so copies may not share a constant id. That is why
 * the styling half needs a SECOND collection: a scalar row has one
 * field to spend on an id.
 *
 * Contract: tools/scenes/a11yrows.steps. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>

/* Guest-allocated ids. WIDGETS AND TEMPLATE NODES SHARE ONE SPACE, so the
 * N_ run continues the W_ one; collections count from 1 in their own
 * (DESIGN.md, Binding conventions). */
#define W_ROOT 1
#define W_FOR_NOTES 2
#define W_FOR_HEADS 3
#define C_NOTES 1
#define C_HEADS 2

/* One run of the space across both templates. */
#define N_FIELD 4
#define N_BAR 5
#define N_TITLE 6

/* A scalar collection has no record: its element IS the string, at
 * field 0. */
#define F_NOTE 0
#define F_HEAD 0

static void build_scene(void) {
    uint8_t buf[2048];
    KayaTx tx = {buf, 0, sizeof buf};

    kaya_tx_create_widget(&tx, W_ROOT, KAYA_KIND_COLUMN);

    kaya_tx_create_collection(&tx, C_NOTES,
                              (KayaVariantSchema[]){{(uint32_t[]){KAYA_VALUE_STR}, 1}}, 1);
    kaya_tx_create_for(&tx, W_FOR_NOTES, C_NOTES);
    kaya_tx_create_widget(&tx, N_FIELD, KAYA_KIND_ENTRY);
    /* `level` 0: the element of the For this node sits directly inside. */
    kaya_tx_bind_a11y_id_element(&tx, N_FIELD, 0, F_NOTE);
    kaya_tx_bind_a11y_label_element(&tx, N_FIELD, 0, F_NOTE);
    kaya_tx_template_end(&tx);

    /* `heading` is the one role with a real-tree observable on every
     * platform. The role and inset are CONSTANTS: no binding has an
     * element-sourced spelling of either. */
    kaya_tx_create_collection(&tx, C_HEADS,
                              (KayaVariantSchema[]){{(uint32_t[]){KAYA_VALUE_STR}, 1}}, 1);
    kaya_tx_create_for(&tx, W_FOR_HEADS, C_HEADS);
    kaya_tx_create_widget(&tx, N_BAR, KAYA_KIND_ROW);
    kaya_tx_set_inset(&tx, N_BAR, 8.0);
    kaya_tx_create_widget(&tx, N_TITLE, KAYA_KIND_LABEL);
    kaya_tx_bind_text_element(&tx, N_TITLE, 0, F_HEAD);
    kaya_tx_set_role(&tx, N_TITLE, KAYA_ROLE_HEADING);
    kaya_tx_bind_a11y_id_element(&tx, N_TITLE, 0, F_HEAD);
    kaya_tx_add_child(&tx, N_BAR, N_TITLE);
    kaya_tx_template_end(&tx);

    kaya_tx_add_child(&tx, W_ROOT, W_FOR_NOTES);
    kaya_tx_add_child(&tx, W_ROOT, W_FOR_HEADS);
    kaya_tx_mount(&tx, 0, W_ROOT); /* window 0: the default */

    /* Keys are scoped to their collection, so both start again at 1. */
    kaya_tx_collection_insert(&tx, C_NOTES, 0, 0, kaya_i64(1), 0,
                              (KayaVal[]){kaya_str("First note")}, 1);
    kaya_tx_collection_insert(&tx, C_NOTES, 0, 0, kaya_i64(2), 0,
                              (KayaVal[]){kaya_str("Second note")}, 1);
    kaya_tx_collection_insert(&tx, C_HEADS, 0, 0, kaya_i64(1), 0,
                              (KayaVal[]){kaya_str("Heading one")}, 1);
    kaya_tx_collection_insert(&tx, C_HEADS, 0, 0, kaya_i64(2), 0,
                              (KayaVal[]){kaya_str("Heading two")}, 1);

    kaya_submit(tx.buf, tx.len);
}

static void *app(void *arg) {
    (void)arg;
    build_scene();
    const uint8_t *rec;
    while (kaya_next_occurrence(&rec) != 0) {
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
