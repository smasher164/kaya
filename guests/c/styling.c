/* The styling conformance scene from C, on the function floor: the
 * brand accent, the role tier and the window inset — slice 1's whole
 * surface (docs/styling-plan.md), spelled with the generated packers
 * and nothing above them.
 *
 * THE ACCENT IS FOUR WORDS AND ONE OF THEM MATTERS HERE. D1's grammar
 * is a required seed plus OPTIONAL per-appearance overrides, so the
 * record carries {seed, mask, light, dark}; an app that states only a
 * brand hex sends mask 0 and the core fills both appearances from the
 * seed. What no tier sends — not the sugar, not this floor — is a
 * foreground or a contrast variant: the core derives fill, on-fill,
 * standalone and the hover/pressed ramp, and hands every backend
 * VALUES. The floor cannot even spell them, which is the point.
 *
 * AND IT IS A REQUEST (D2): a platform may let its user override it,
 * as macOS does while the system accent is not multicolor. The eight
 * bindings say that in one sentence and this file sends the same
 * record; there is no per-platform arm down here to get wrong.
 *
 * THE ORDER OF THE FIRST FOUR RECORDS IS THE CONTRACT, not house
 * style: brand is set ONCE and BEFORE THE FIRST MOUNT — the root
 * refuses a second write and a late one — so the accent leads the
 * transaction and mount closes it. A sugar binding cannot help you
 * here either; the wall is in the root, and every language walks into
 * the same one.
 *
 * THE ROLES ARE CONSTANTS FROM A CLOSED ENUM, one per widget, and the
 * root judges the pairing: `heading` fits a label and the two button
 * roles do not, so a misfit dies at declare time before any backend
 * sees it. `role` is one wire slot; the variants divide it.
 *
 * The byte-frozen contract is tools/scenes/styling.steps.
 * Run with KAYA_SELFTEST=styling. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>

/* Guest-allocated ids, counted from 1 per space. THE CREATION ORDER IS
 * READ BY THE SCRIPT: label#0 is the heading and label#1 the status,
 * button#0 Delete and button#1 Save. Swapping either pair would not
 * fail with "no such target" — it would read the wrong widget and
 * compare the wrong string (guests/c/dirty.c makes the same point). */
#define SIG_HEADING 1
#define SIG_STATUS 2

#define W_COLUMN 1
#define W_TITLE 2  /* label#0 */
#define W_STATUS 3 /* label#1 */
#define W_DELETE 4 /* button#0 */
#define W_SAVE 5   /* button#1 */

/* A WINDOW PROP WITH ITS VALUE, PACKED OUT: {u64 window, u32 prop, u32
 * source, value}. The generated kaya_tx_set_window_prop closes the
 * record BEFORE the value — the tail convention it shares with
 * SET_PROPERTY — so a caller with a value to write begins the record
 * itself, which is what every C guest's title already does
 * (guests/c/dirty.c, guests/c/undo.c). One helper for all four here,
 * because title, width, height and inset differ by a constant and a
 * Value kind and by nothing else. */
static void window_prop(KayaTx *tx, uint64_t window, uint32_t prop, KayaVal value) {
    size_t start = kaya_wire_begin(tx, KAYA_TX_SET_WINDOW_PROP);
    kaya_wire_u64(tx, window);
    kaya_wire_u32(tx, prop);
    kaya_wire_u32(tx, KAYA_SOURCE_CONST);
    kaya_wire_value(tx, value);
    kaya_wire_end(tx, start);
}

static void build_scene(void) {
    uint8_t buf[1024];
    KayaTx tx = {buf, 0};

    /* Adwaita blue, the derivation's empirical anchor. mask 0: no
     * per-appearance override, so light and dark both come from the
     * seed. */
    kaya_tx_set_brand_accent(&tx, 0x3584E4, 0, 0, 0);

    window_prop(&tx, 0, KAYA_WPROP_TITLE, kaya_str("styling"));
    window_prop(&tx, 0, KAYA_WPROP_WIDTH, kaya_f64(480.0));
    window_prop(&tx, 0, KAYA_WPROP_HEIGHT, kaya_f64(360.0));
    /* FULL BLEED, AND IT IS LAYOUT (D3): the inset is kaya's own
     * padding inside the mounted root, so 0 is honored unconditionally
     * — nothing platform-side defends it. The safe area on a phone is
     * a separate fact and this does not remove it. F64, beside width
     * and height, because it is a length like they are. */
    window_prop(&tx, 0, KAYA_WPROP_INSET, kaya_f64(0.0));

    kaya_tx_create_signal(&tx, SIG_HEADING, kaya_str("Sections"));
    kaya_tx_create_signal(&tx, SIG_STATUS, kaya_str("ready"));

    kaya_tx_create_widget(&tx, W_COLUMN, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, W_TITLE, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_TITLE, SIG_HEADING);
    kaya_tx_set_role(&tx, W_TITLE, KAYA_ROLE_HEADING);
    /* expect_ax resolves its target through the AUTHORED id into the
     * real tree, so everything the script reads back is identified. */
    kaya_tx_set_a11y_id(&tx, W_TITLE, "title");
    kaya_tx_create_widget(&tx, W_STATUS, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_STATUS, SIG_STATUS);
    kaya_tx_create_widget(&tx, W_DELETE, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_DELETE, "Delete");
    kaya_tx_set_role(&tx, W_DELETE, KAYA_ROLE_DESTRUCTIVE);
    kaya_tx_set_a11y_id(&tx, W_DELETE, "delete");
    kaya_tx_create_widget(&tx, W_SAVE, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_SAVE, "Save");
    kaya_tx_set_role(&tx, W_SAVE, KAYA_ROLE_PROMINENT);
    kaya_tx_set_a11y_id(&tx, W_SAVE, "save");

    kaya_tx_add_child(&tx, W_COLUMN, W_TITLE);
    kaya_tx_add_child(&tx, W_COLUMN, W_STATUS);
    kaya_tx_add_child(&tx, W_COLUMN, W_DELETE);
    kaya_tx_add_child(&tx, W_COLUMN, W_SAVE);
    kaya_tx_mount(&tx, 0, W_COLUMN); /* window 0: the default */

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
        /* A ROLE NEVER CHANGES WHAT A BUTTON DOES. These two handlers
         * are the semantics half of the roles' contract: destructive
         * and prominent press like any button, and the app is what
         * acts. Nothing here reads the role back — the emphasis is the
         * platform's chrome, held by the lowerings' own gates. */
        const char *status = NULL;
        if (id == W_DELETE)
            status = "deleted";
        else if (id == W_SAVE)
            status = "saved";
        if (status == NULL)
            continue;
        uint8_t out[256];
        KayaTx tx = {out, 0};
        kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str(status));
        kaya_submit(tx.buf, tx.len);
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
