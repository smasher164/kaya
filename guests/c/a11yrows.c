/* The stamped-accessibility scene from C, on the function floor: one
 * template entry whose a11y id AND a11y label come from the row's own
 * value, read back out of the PLATFORM'S OWN accessibility tree — and
 * beside it a second collection whose prototype carries a stamped row's
 * inset and a stamped label's role (docs/tpl-props-plan.md).
 *
 * BOTH A11Y PROPS ARE ELEMENT-SOURCED AND THE ID IS FORCED: expect_ax
 * resolves its target by the authored identifier and REFUSES an
 * ambiguous one, so copies sharing a constant id cannot be read back
 * (swift/KayaSwiftUI.swift's expect_ax). A shared constant id stays
 * legal; it is simply unreadable. The same limit is why the styling
 * half needs a SECOND collection: a scalar row has one field to spend
 * on an id.
 *
 * A SEPARATE SCENE FROM a11y.c BY SHAPE: a For materializes as a column
 * and harness registries are creation-order, so a scene that asserts
 * container kinds ordinally cannot host one. This scene asserts no
 * container ordinally except the stamped row.
 *
 * The byte-frozen contract is tools/scenes/a11yrows.steps.
 * Run with KAYA_SELFTEST=a11yrows. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>

/* Guest-allocated ids, counted from 1 per space. */
#define W_ROOT 1
#define W_FOR_NOTES 2
#define W_FOR_HEADS 3
#define C_NOTES 1
#define C_HEADS 2

/* Template nodes: their own id space, never widget ids. One run of the
 * space across both templates. */
#define N_FIELD 1
#define N_BAR 2
#define N_TITLE 3

/* A scalar collection has no record: its element IS the string, at
 * field 0. */
#define F_NOTE 0
#define F_HEAD 0

static void build_scene(void) {
    uint8_t buf[2048];
    KayaTx tx = {buf, 0};

    kaya_tx_create_widget(&tx, W_ROOT, KAYA_KIND_COLUMN);

    kaya_tx_create_collection(&tx, C_NOTES,
                              (KayaVariantSchema[]){{(uint32_t[]){KAYA_VALUE_STR}, 1}}, 1);
    kaya_tx_create_for(&tx, W_FOR_NOTES, C_NOTES);
    kaya_tx_create_widget(&tx, N_FIELD, KAYA_KIND_ENTRY);
    /* `level` is 0: the element of the For this node sits directly
     * inside. */
    kaya_tx_bind_a11y_id_element(&tx, N_FIELD, 0, F_NOTE);
    kaya_tx_bind_a11y_label_element(&tx, N_FIELD, 0, F_NOTE);
    kaya_tx_template_end(&tx);

    /* The styling half. `heading` is the one role with a real-tree
     * observable on every platform, which is why the script reads it and
     * not the other two. The role and inset are CONSTANTS: there is no
     * element-sourced spelling of either, in any binding. */
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
    /* No handler: the loop blocks until shutdown. */
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
