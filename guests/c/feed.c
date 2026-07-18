/* The feed scene from C, on the function floor: sum-typed elements
 * with the discriminants spelled by hand — the desugared form every
 * binding's sum surface lowers to. The collection declares two variant
 * schemas, the For declares one case per constructor (totality is the
 * scene's check either way), promote re-sends an entry under the other
 * constructor (the core restamps it in place), and the toggle's field
 * write carries the witnessed variant.
 *
 * Built and run by the Linux container suite with KAYA_SELFTEST=feed. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* Guest-allocated ids, counted from 1 per space. */
#define SIG_DONE 1
#define W_ROW 1
#define W_PROMOTE 2
#define W_STATUS 3
#define W_FOR_FEED 4
#define C_FEED 1
#define N_NOTE_TEXT 1
#define N_TODO_ROW 2
#define N_TODO_CHECK 3
#define N_TODO_TITLE 4

/* The constructors' discriminants and field indexes: the C floor's
 * "sum tokens". */
#define V_NOTE 0
#define V_TODO 1
#define F_NOTE_TEXT 0
#define F_TODO_TITLE 0
#define F_TODO_DONE 1

/* The model, hand-kept per C's no-binding-model decision. */
#define N_POSTS 3
static struct {
    char key[8];
    uint32_t variant;
    char text[32];
    int done;
} posts[N_POSTS] = {
    {"a", V_NOTE, "jot one", 0},
    {"b", V_TODO, "buy milk", 0},
    {"c", V_NOTE, "jot two", 0},
};

static void build_scene(void) {
    uint8_t buf[1024];
    KayaTx tx = {buf, 0};

    kaya_tx_create_signal(&tx, SIG_DONE, kaya_str("0 done"));
    kaya_tx_create_widget(&tx, W_ROW, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, W_PROMOTE, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_PROMOTE, "promote");
    kaya_tx_create_widget(&tx, W_STATUS, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_STATUS, SIG_DONE);

    kaya_tx_create_collection(
        &tx, C_FEED,
        (KayaVariantSchema[]){
            {(uint32_t[]){KAYA_VALUE_STR}, 1},
            {(uint32_t[]){KAYA_VALUE_STR, KAYA_VALUE_BOOL}, 2},
        },
        2);
    kaya_tx_create_for(&tx, W_FOR_FEED, C_FEED);
    kaya_tx_variant_case(&tx, V_NOTE);
    kaya_tx_create_widget(&tx, N_NOTE_TEXT, KAYA_KIND_LABEL);
    kaya_tx_bind_text_element(&tx, N_NOTE_TEXT, 0, F_NOTE_TEXT);
    kaya_tx_variant_case(&tx, V_TODO);
    kaya_tx_create_widget(&tx, N_TODO_ROW, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, N_TODO_CHECK, KAYA_KIND_CHECKBOX);
    kaya_tx_bind_checked_element(&tx, N_TODO_CHECK, 0, F_TODO_DONE);
    kaya_tx_create_widget(&tx, N_TODO_TITLE, KAYA_KIND_LABEL);
    kaya_tx_bind_text_element(&tx, N_TODO_TITLE, 0, F_TODO_TITLE);
    kaya_tx_add_child(&tx, N_TODO_ROW, N_TODO_CHECK);
    kaya_tx_add_child(&tx, N_TODO_ROW, N_TODO_TITLE);
    kaya_tx_template_end(&tx);

    kaya_tx_add_child(&tx, W_ROW, W_PROMOTE);
    kaya_tx_add_child(&tx, W_ROW, W_STATUS);
    kaya_tx_add_child(&tx, W_ROW, W_FOR_FEED);
    kaya_tx_mount(&tx, 0, W_ROW); /* window 0: the default */

    for (unsigned i = 0; i < N_POSTS; i++) {
        if (posts[i].variant == V_NOTE)
            kaya_tx_collection_insert(&tx, C_FEED, 0, 0, kaya_str(posts[i].key),
                                      V_NOTE,
                                      (KayaVal[]){kaya_str(posts[i].text)}, 1);
        else
            kaya_tx_collection_insert(
                &tx, C_FEED, 0, 0, kaya_str(posts[i].key), V_TODO,
                (KayaVal[]){kaya_str(posts[i].text), kaya_bool(posts[i].done)},
                2);
    }

    kaya_submit(tx.buf, tx.len);
}

static void write_done_count(KayaTx *tx) {
    unsigned done = 0;
    for (unsigned i = 0; i < N_POSTS; i++)
        if (posts[i].variant == V_TODO && posts[i].done)
            done += 1;
    char status[32];
    snprintf(status, sizeof status, "%u done", done);
    kaya_tx_write_signal(tx, SIG_DONE, kaya_str(status));
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
        KayaVal keys[2], payload;
        uint32_t n_keys;
        if (kaya_parse_toggled(rec, &id, keys, 2, &n_keys, &payload)) {
            if (id != N_TODO_CHECK || n_keys != 1)
                continue;
            for (unsigned i = 0; i < N_POSTS; i++) {
                if (keys[0].s_len != strlen(posts[i].key) ||
                    memcmp(keys[0].s, posts[i].key, keys[0].s_len) != 0)
                    continue;
                /* The variant check is the refinement, and the write
                 * carries it as the witness. */
                if (posts[i].variant != V_TODO)
                    break;
                posts[i].done = payload.i != 0;
                uint8_t buf[512];
                KayaTx tx = {buf, 0};
                kaya_tx_collection_update_field(&tx, C_FEED, 0, 0, keys[0],
                                                F_TODO_DONE, V_TODO,
                                                kaya_bool(posts[i].done));
                write_done_count(&tx);
                kaya_submit(tx.buf, tx.len);
                break;
            }
        } else if (kaya_parse_click(rec, &id, keys, 2, &n_keys)) {
            if (id != W_PROMOTE || n_keys != 0)
                continue;
            for (unsigned i = 0; i < N_POSTS; i++) {
                if (posts[i].variant != V_NOTE)
                    continue;
                /* Promote: the same key re-sent under the other
                 * constructor; the core restamps its copy in place. */
                posts[i].variant = V_TODO;
                posts[i].done = 1;
                uint8_t buf[512];
                KayaTx tx = {buf, 0};
                kaya_tx_collection_update(
                    &tx, C_FEED, 0, 0, kaya_str(posts[i].key), V_TODO,
                    (KayaVal[]){kaya_str(posts[i].text), kaya_bool(1)}, 2);
                write_done_count(&tx);
                kaya_submit(tx.buf, tx.len);
                break;
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
