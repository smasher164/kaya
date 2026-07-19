/* The todos scene from C, on the function floor: records and field
 * projection with indexes spelled by hand — the desugared form every
 * derive lowers to. The collection declares a {Str, Bool} schema, the
 * template binds field 0 to a label and field 1 to a checkbox, and the
 * toggle handler sends one field's delta — the title never travels.
 *
 * Built and run by the Linux container suite with KAYA_SELFTEST=todos. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* Guest-allocated ids, counted from 1 per space. */
#define SIG_LEFT 1
#define W_COLUMN 1
#define W_FIELD 2
#define W_ADD 3
#define W_STATUS 4
#define W_FOR_TODOS 5
#define C_TODOS 1
#define N_ROW 1
#define N_CHECK 2
#define N_TITLE 3

/* The record's field indexes: the C floor's "field tokens". */
#define F_TITLE 0
#define F_DONE 1

static void build_scene(void) {
    uint8_t buf[1024];
    KayaTx tx = {buf, 0};

    kaya_tx_create_signal(&tx, SIG_LEFT, kaya_str("0 items left"));
    kaya_tx_create_widget(&tx, W_COLUMN, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, W_FIELD, KAYA_KIND_ENTRY);
    kaya_tx_create_widget(&tx, W_ADD, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_ADD, "Add");
    kaya_tx_create_widget(&tx, W_STATUS, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_STATUS, SIG_LEFT);

    kaya_tx_create_collection(
        &tx, C_TODOS,
        (KayaVariantSchema[]){{(uint32_t[]){KAYA_VALUE_STR, KAYA_VALUE_BOOL}, 2}}, 1);
    kaya_tx_create_for(&tx, W_FOR_TODOS, C_TODOS);
    kaya_tx_create_widget(&tx, N_ROW, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, N_CHECK, KAYA_KIND_CHECKBOX);
    kaya_tx_bind_checked_element(&tx, N_CHECK, 0, F_DONE);
    kaya_tx_create_widget(&tx, N_TITLE, KAYA_KIND_LABEL);
    kaya_tx_bind_text_element(&tx, N_TITLE, 0, F_TITLE);
    kaya_tx_add_child(&tx, N_ROW, N_CHECK);
    kaya_tx_add_child(&tx, N_ROW, N_TITLE);
    kaya_tx_template_end(&tx);

    kaya_tx_add_child(&tx, W_COLUMN, W_FIELD);
    kaya_tx_add_child(&tx, W_COLUMN, W_ADD);
    kaya_tx_add_child(&tx, W_COLUMN, W_STATUS);
    kaya_tx_add_child(&tx, W_COLUMN, W_FOR_TODOS);
    kaya_tx_mount(&tx, 0, W_COLUMN); /* window 0: the default */

    kaya_submit(tx.buf, tx.len);
}

/* The model, hand-kept per C's no-binding-model decision. */
#define MAX_TODOS 32
static struct {
    char key[16];
    int done;
} todos[MAX_TODOS];
static unsigned n_todos = 0;

static void write_items_left(KayaTx *tx) {
    unsigned left = 0;
    for (unsigned i = 0; i < n_todos; i++)
        if (!todos[i].done)
            left += 1;
    char status[32];
    snprintf(status, sizeof status, left == 1 ? "%u item left" : "%u items left",
             left);
    kaya_tx_write_signal(tx, SIG_LEFT, kaya_str(status));
}

static void *app(void *arg) {
    (void)arg;
    build_scene();
    char draft[128] = "";
    uint8_t rec[512];
    for (;;) {
        size_t size = kaya_next_occurrence(rec, sizeof rec);
        if (size == 0)
            break; /* shutdown */
        uint64_t id;
        KayaVal keys[2], payload;
        uint32_t n_keys;
        if (kaya_parse_text_changed(rec, &id, keys, 2, &n_keys, &payload)) {
            if (id == W_FIELD && n_keys == 0) {
                unsigned len = payload.s_len < sizeof draft - 1
                    ? payload.s_len : (unsigned)sizeof draft - 1;
                memcpy(draft, payload.s, len);
                draft[len] = 0;
            }
        } else if (kaya_parse_toggled(rec, &id, keys, 2, &n_keys, &payload)) {
            if (id == N_CHECK && n_keys == 1) {
                for (unsigned i = 0; i < n_todos; i++) {
                    if (keys[0].s_len == strlen(todos[i].key) &&
                        memcmp(keys[0].s, todos[i].key, keys[0].s_len) == 0) {
                        todos[i].done = payload.i != 0;
                    }
                }
                uint8_t buf[512];
                KayaTx tx = {buf, 0};
                /* One field's delta: the title never travels. The 0
                 * after F_DONE is the witnessed variant — a record
                 * collection has one constructor. */
                kaya_tx_collection_update_field(&tx, C_TODOS, 0, 0, keys[0],
                                                F_DONE, 0,
                                                kaya_bool(payload.i != 0));
                write_items_left(&tx);
                kaya_submit(tx.buf, tx.len);
            }
        } else if (kaya_parse_click(rec, &id, keys, 2, &n_keys)) {
            if (id == W_ADD && n_keys == 0 && n_todos < MAX_TODOS) {
                /* The empty-draft guard every real form has: nothing to
                 * insert, nothing to command. */
                if (draft[0] == '\0')
                    continue;
                snprintf(todos[n_todos].key, sizeof todos[n_todos].key, "t%u",
                         n_todos + 1);
                todos[n_todos].done = 0;
                n_todos += 1;
                uint8_t buf[512];
                KayaTx tx = {buf, 0};
                kaya_tx_collection_insert(
                    &tx, C_TODOS, 0, 0, kaya_str(todos[n_todos - 1].key), 0,
                    (KayaVal[]){kaya_str(draft), kaya_bool(0)}, 2);
                write_items_left(&tx);
                /* Finish the form: the field empties on screen and
                 * reports text_changed("") through its normal edit path
                 * (the fold empties the draft), and the cursor lands
                 * back in it. */
                kaya_tx_widget_command(&tx, W_FIELD, KAYA_COMMAND_CLEAR);
                kaya_tx_widget_command(&tx, W_FIELD, KAYA_COMMAND_FOCUS);
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
