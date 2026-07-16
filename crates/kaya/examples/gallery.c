/* The gallery scene from C, on the function floor: a row container
 * laying a checkbox and the status label side by side. The box owns
 * its checked bit and reports each flip as a toggled occurrence; the
 * app answers by writing the status signal — the same uncontrolled
 * contract as the entry, with a bool.
 *
 * Built and run by the Linux container suite with KAYA_SELFTEST=gallery. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>

/* Guest-allocated ids, counted from 1 per space. */
#define SIG_STATUS 1
#define W_COLUMN 1
#define W_ROW 2
#define W_URGENT 3
#define W_STATUS 4

static void build_scene(void) {
    uint8_t buf[1024];
    KayaTx tx = {buf, 0};

    kaya_tx_create_signal(&tx, SIG_STATUS, kaya_str("urgent: false"));
    kaya_tx_create_widget(&tx, W_COLUMN, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, W_ROW, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, W_URGENT, KAYA_KIND_CHECKBOX);
    kaya_tx_set_text(&tx, W_URGENT, "urgent");
    kaya_tx_create_widget(&tx, W_STATUS, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_STATUS, SIG_STATUS);

    kaya_tx_add_child(&tx, W_ROW, W_URGENT);
    kaya_tx_add_child(&tx, W_ROW, W_STATUS);
    kaya_tx_add_child(&tx, W_COLUMN, W_ROW);
    kaya_tx_mount(&tx, 0, W_COLUMN); /* window 0: the default */

    kaya_submit(tx.buf, tx.len);
}

static void *app(void *arg) {
    (void)arg;
    build_scene();
    uint8_t rec[512];
    for (;;) {
        size_t size = kaya_next_occurrence(rec, sizeof rec);
        if (size == 0)
            break; /* shutdown */
        uint64_t id;
        KayaVal keys[2], checked;
        uint32_t n_keys;
        if (kaya_parse_toggled(rec, &id, keys, 2, &n_keys, &checked)) {
            if (id == W_URGENT && n_keys == 0) {
                uint8_t buf[256];
                KayaTx tx = {buf, 0};
                char status[32];
                snprintf(status, sizeof status, "urgent: %s",
                         checked.i ? "true" : "false");
                kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str(status));
                kaya_submit(tx.buf, tx.len);
            }
        }
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
