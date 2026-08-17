/* The stamped-accessibility scene from C, on the function floor: one
 * template entry whose a11y id AND a11y label come from the row's own
 * value, stamped twice, read back out of the PLATFORM'S OWN
 * accessibility tree — and beside it a second collection whose
 * prototype carries the STYLING props, a stamped row's inset and a
 * stamped label's role.
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
 * THE SAME SENTENCE IS WHY C GAINS NO SURFACE FOR THE STYLING PROPS.
 * A template node's role and inset are kaya_tx_set_role and
 * kaya_tx_set_inset, byte for byte the records guests/c/styling.c sends
 * at a live widget: the template zone rides SET_PROPERTY, so the floor
 * already spelled both before the sugar tiers could. The eight sugar
 * bindings grew a template-zone method each; this file gained two
 * calls it could always have made.
 *
 * BOTH A11Y PROPS ELEMENT-SOURCED, and the id is the forced one. The
 * label is the point of the feature: a list row announcing its own name
 * to assistive tech. The id has to follow because expect_ax resolves
 * its target to the node's authored identifier and then searches the
 * real tree BY that identifier, so copies sharing one constant id are
 * indistinguishable to it — the read refuses an ambiguous id with the
 * count it measured rather than answering with whichever element it
 * found first, which is what it did the first time these assertions
 * ran. A shared constant id stays legal, nothing in the core
 * deduplicates; it is simply not a thing that verb can read back.
 *
 * THE STYLING PROPS ARE CONSTANTS, and there is no element-sourced
 * spelling of them anywhere — not here, where the floor could trivially
 * emit one, and not in any binding. What a copy MEANS, and how far its
 * prototype holds children off its edge, are facts about the PROTOTYPE
 * and not about the row's data.
 *
 * A SECOND COLLECTION RATHER THAN TWO MORE WIDGETS IN THE FIRST, for
 * expect_ax's reason again: a scalar row has exactly one field to spend
 * on an id, so a second readable stamped element needs its own strings.
 *
 * A SEPARATE SCENE BY SHAPE, not by size: a For materializes as a
 * column, harness registries are creation-order, and container creation
 * order differs by language — so the a11y scene, which asserts every
 * container kind ordinally, cannot host a For without column#0 naming
 * different widgets on different lanes. This scene asserts no container
 * ordinally except the stamped row, which only this collection makes,
 * so the Fors' columns may land at either end of the registry
 * (guests/haskell/reorder.hs documents the ordering rule).
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
 * space across both templates, as guests/c/milestone2.c numbers its
 * two. */
#define N_FIELD 1
#define N_BAR 2
#define N_TITLE 3

/* A scalar collection has no record: its element IS the string, and
 * that is field 0. The sugar has a name for it — kaya::Field::element()
 * in the Rust binding, which is a Field at index 0 — and both spellings
 * put the same two u32s on the wire. */
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
    /* The two records the a11y half of this scene exists to send.
     * `level` is 0 — the element of the For this node sits directly
     * inside. */
    kaya_tx_bind_a11y_id_element(&tx, N_FIELD, 0, F_NOTE);
    kaya_tx_bind_a11y_label_element(&tx, N_FIELD, 0, F_NOTE);
    kaya_tx_template_end(&tx);

    /* The styling half. `heading` is the role with a real-tree
     * observable on every platform (which is why styling.steps freezes
     * it and not the other two), so the stamped label's role is read
     * exactly as the live one's is — on an element that was never
     * authored, only stamped. The row's inset is the window inset one
     * level down, and the editor's find bar is why it exists: a
     * STAMPED row sat flush against a full-bleed window while the live
     * status row beside it inset. */
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

    /* THE FLOOR HAS NO insert_fresh: the sugar's fresh key is a counter
     * the binding keeps, and its keys cross the wire as I64s exactly
     * the way these do — guests/c/undo.c mints its own the same way.
     * The key names the row; the row's VALUE is what the copy
     * announces. Keys are scoped to their collection, so both start
     * again at 1. */
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
