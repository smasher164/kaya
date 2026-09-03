/* The reorder scene (tools/scenes/reorder.steps). THE ROOT IS A ROW so the
 * For's container is the only column, and column#0 names it everywhere. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* WIDGETS AND TEMPLATE NODES SHARE ONE SPACE, so the N_ run continues the
 * W_ one; collections count from 1 in their own (tools/check-c-ids.py). */
#define W_ROW 1
#define W_ROTATE 2
#define W_LIFT 3
#define W_FOR_ITEMS 4
#define C_ITEMS 1
#define N_TITLE 5

#define F_TITLE 0

/* The keys in collection order; each title equals its key. */
#define N_ITEMS 3
static char order[N_ITEMS][2] = {"a", "b", "c"};

static void build_scene(void) {
    uint8_t buf[1024];
    KayaTx tx = {buf, 0, sizeof buf};

    kaya_tx_create_widget(&tx, W_ROW, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, W_ROTATE, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_ROTATE, "rotate");
    kaya_tx_create_widget(&tx, W_LIFT, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_LIFT, "lift");

    kaya_tx_create_collection(&tx, C_ITEMS,
                              (KayaVariantSchema[]){{(uint32_t[]){KAYA_VALUE_STR}, 1}}, 1);
    kaya_tx_create_for(&tx, W_FOR_ITEMS, C_ITEMS);
    kaya_tx_create_widget(&tx, N_TITLE, KAYA_KIND_LABEL);
    kaya_tx_bind_text_element(&tx, N_TITLE, 0, F_TITLE);
    kaya_tx_template_end(&tx);

    kaya_tx_add_child(&tx, W_ROW, W_ROTATE);
    kaya_tx_add_child(&tx, W_ROW, W_LIFT);
    kaya_tx_add_child(&tx, W_ROW, W_FOR_ITEMS);
    kaya_tx_mount(&tx, 0, W_ROW); /* window 0: the default */

    for (unsigned i = 0; i < N_ITEMS; i++)
        kaya_tx_collection_insert(&tx, C_ITEMS, 0, 0, kaya_str(order[i]), 0,
                                  (KayaVal[]){kaya_str(order[i])}, 1);

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
            continue; /* no record; rec is NULL */
        uint64_t id;
        KayaVal keys[2];
        uint32_t n_keys;
        if (!kaya_parse_click(rec, &id, keys, 2, &n_keys) || n_keys != 0)
            continue;
        if (id == W_ROTATE) {
            char moved[2];
            memcpy(moved, order[0], sizeof moved);
            for (unsigned i = 0; i + 1 < N_ITEMS; i++)
                memcpy(order[i], order[i + 1], sizeof order[i]);
            memcpy(order[N_ITEMS - 1], moved, sizeof moved);

            uint8_t buf[256];
            KayaTx tx = {buf, 0, sizeof buf};
            kaya_tx_collection_move(&tx, C_ITEMS, 0, 0, kaya_str(moved), 0, 0);
            kaya_submit(tx.buf, tx.len);
        } else if (id == W_LIFT) {
            char moved[2], anchor[2];
            memcpy(moved, order[N_ITEMS - 1], sizeof moved);
            memcpy(anchor, order[0], sizeof anchor);
            for (unsigned i = N_ITEMS - 1; i > 0; i--)
                memcpy(order[i], order[i - 1], sizeof order[i]);
            memcpy(order[0], moved, sizeof moved);

            uint8_t buf[256];
            KayaTx tx = {buf, 0, sizeof buf};
            kaya_tx_collection_move(&tx, C_ITEMS, 0, 0, kaya_str(moved),
                                    (KayaVal[]){kaya_str(anchor)}, 1);
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
