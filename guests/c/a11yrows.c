/* The stamped-accessibility scene from C, on the function floor: one
 * template entry whose a11y id AND a11y label come from the row's own
 * value, stamped twice, read back out of the PLATFORM'S OWN
 * accessibility tree.
 *
 * The a11y scene proves the wrap-native bet for LIVE widgets; this one
 * proves it for COPIES — the case none of the accessibility milestone's
 * 719 legs exercised, because until the template zone could carry the
 * props (docs/tpl-props-plan.md P1) no guest could author a stamped
 * widget's name at all.
 *
 * The floor is the point here, as in guests/c/a11y.c. Naming a live
 * widget and naming a copy are the same record with a different SOURCE:
 * kaya_tx_set_a11y_id carries a constant, kaya_tx_bind_a11y_id_element
 * carries the enclosing For's element. Every other language spells the
 * second one as sugar — a chain, a kwarg, a labeled argument — and none
 * of them puts anything else on the wire.
 *
 * BOTH PROPS ELEMENT-SOURCED, and the id is the forced one. The label
 * is the point of the feature: a list row announcing its own name to
 * assistive tech. The id has to follow because expect_ax resolves its
 * target to the node's authored identifier and then searches the real
 * tree BY that identifier, so copies sharing one constant id are
 * indistinguishable to it — the read refuses an ambiguous id with the
 * count it measured rather than answering with whichever element it
 * found first, which is what it did the first time these assertions
 * ran. A shared constant id stays legal, nothing in the core
 * deduplicates; it is simply not a thing that verb can read back.
 *
 * A SEPARATE SCENE BY SHAPE, not by size: a For materializes as a
 * column, harness registries are creation-order, and container creation
 * order differs by language — so the a11y scene, which asserts every
 * container kind ordinally, cannot host a For without column#0 naming
 * different widgets on different lanes. This scene asserts no container
 * at all, so the For's column may land at either end of the registry
 * (guests/haskell/reorder.hs documents the ordering rule).
 *
 * The byte-frozen contract is tools/scenes/a11yrows.steps.
 * Run with KAYA_SELFTEST=a11yrows. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>

/* Guest-allocated ids, counted from 1 per space. */
#define W_NOTES 1
#define W_FOR_NOTES 2
#define C_NOTES 1

/* Template nodes: their own id space, never widget ids. */
#define N_FIELD 1

/* A scalar collection has no record: its element IS the string, and
 * that is field 0. The sugar has a name for it — kaya::Field::element()
 * in the Rust binding, which is a Field at index 0 — and both spellings
 * put the same two u32s on the wire. */
#define F_NOTE 0

static void build_scene(void) {
    uint8_t buf[1024];
    KayaTx tx = {buf, 0};

    kaya_tx_create_widget(&tx, W_NOTES, KAYA_KIND_COLUMN);

    kaya_tx_create_collection(&tx, C_NOTES,
                              (KayaVariantSchema[]){{(uint32_t[]){KAYA_VALUE_STR}, 1}}, 1);
    kaya_tx_create_for(&tx, W_FOR_NOTES, C_NOTES);
    kaya_tx_create_widget(&tx, N_FIELD, KAYA_KIND_ENTRY);
    /* The two records this whole scene exists to send. `level` is 0 —
     * the element of the For this node sits directly inside. */
    kaya_tx_bind_a11y_id_element(&tx, N_FIELD, 0, F_NOTE);
    kaya_tx_bind_a11y_label_element(&tx, N_FIELD, 0, F_NOTE);
    kaya_tx_template_end(&tx);

    kaya_tx_add_child(&tx, W_NOTES, W_FOR_NOTES);
    kaya_tx_mount(&tx, 0, W_NOTES); /* window 0: the default */

    /* THE FLOOR HAS NO insert_fresh: the sugar's fresh key is a counter
     * the binding keeps, and its keys cross the wire as I64s exactly
     * the way these do — guests/c/undo.c mints its own the same way.
     * The key names the row; the row's VALUE is what the copy
     * announces. */
    kaya_tx_collection_insert(&tx, C_NOTES, 0, 0, kaya_i64(1), 0,
                              (KayaVal[]){kaya_str("First note")}, 1);
    kaya_tx_collection_insert(&tx, C_NOTES, 0, 0, kaya_i64(2), 0,
                              (KayaVal[]){kaya_str("Second note")}, 1);

    kaya_submit(tx.buf, tx.len);
}

static void *app(void *arg) {
    (void)arg;
    build_scene();
    /* A static scene: nothing here needs a handler, so the occurrence
     * loop exists purely to block until shutdown (the keep-alive idiom
     * every handler-less scene uses). */
    const uint8_t *rec;
    while (kaya_next_occurrence(&rec) != 0) {
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
