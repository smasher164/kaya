/* The milestone-2 scene from C over the C ABI (function floor): the
 * ABI's home language validated the same way as every other guest. The
 * main thread enters kaya_run() and becomes the core's UI thread; a
 * pthread is the app thread, draining occurrences and answering with
 * packed transaction records through kaya_submit. The scene declares a
 * When (the extras banner) and a nested For (groups holding items);
 * clicks on stamped remove buttons come back as a template node id plus
 * key path, and the app answers by removing that entry.
 *
 * Built and run by the Linux container suite (tools/linux/run-suites.sh),
 * where a plain cc and the shared library are both at hand. */

#include <kaya.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* Guest-allocated ids, counted from 1 per space. */
#define SIG_STATUS 1
#define SIG_EXTRAS 2
#define W_COLUMN 1
#define W_STEP 2
#define W_STATUS 3
#define W_WHEN 4
#define W_FOR_GROUPS 5
#define C_GROUPS 1
#define C_ITEMS 2
#define N_BANNER 1
#define N_GROUP_COL 2
#define N_GROUP_NAME 3
#define N_ITEMS_FOR 4
#define N_ITEM_ROW 5
#define N_ITEM_TEXT 6
#define N_REMOVE 7

/* --- Transaction packing (KAYA_TX_* layouts from kaya.h) ------------- */

typedef struct {
    uint8_t bytes[2048];
    size_t len;
} Tx;

/* Start a record: {u32 size, u16 kind, u16 flags}; the body follows.
 * Returns the record's start for finish(). */
static size_t record(Tx *tx, uint16_t kind) {
    size_t start = tx->len;
    memset(tx->bytes + tx->len, 0, 8);
    memcpy(tx->bytes + tx->len + 4, &kind, 2);
    tx->len += 8;
    return start;
}

static void put_u32(Tx *tx, uint32_t v) {
    memcpy(tx->bytes + tx->len, &v, 4);
    tx->len += 4;
}

static void put_u64(Tx *tx, uint64_t v) {
    memcpy(tx->bytes + tx->len, &v, 8);
    tx->len += 8;
}

/* Values are self-padded to 8: they concatenate inside record bodies. */
static void put_str(Tx *tx, const char *s) {
    uint32_t len = (uint32_t)strlen(s);
    put_u32(tx, KAYA_VALUE_STR);
    put_u32(tx, len);
    memcpy(tx->bytes + tx->len, s, len);
    tx->len += len;
    while (tx->len % 8 != 0)
        tx->bytes[tx->len++] = 0;
}

static void put_bool(Tx *tx, int v) {
    put_u32(tx, KAYA_VALUE_BOOL);
    put_u32(tx, 1);
    tx->bytes[tx->len++] = (uint8_t)(v != 0);
    while (tx->len % 8 != 0)
        tx->bytes[tx->len++] = 0;
}

/* A key path: {u32 count, u32 reserved, count values}. */
static void put_path1(Tx *tx, const char *key) {
    put_u32(tx, 1);
    put_u32(tx, 0);
    put_str(tx, key);
}

static void put_path0(Tx *tx) {
    put_u32(tx, 0);
    put_u32(tx, 0);
}

static void finish(Tx *tx, size_t start) {
    while (tx->len % 8 != 0)
        tx->bytes[tx->len++] = 0;
    uint32_t size = (uint32_t)(tx->len - start);
    memcpy(tx->bytes + start, &size, 4);
}

static void submit(const Tx *tx) {
    kaya_submit(tx->bytes, tx->len);
}

static void create_widget(Tx *tx, uint64_t id, uint32_t kind) {
    size_t s = record(tx, KAYA_TX_CREATE_WIDGET);
    put_u64(tx, id);
    put_u32(tx, kind);
    put_u32(tx, 0);
    finish(tx, s);
}

static void set_text_const(Tx *tx, uint64_t id, const char *text) {
    size_t s = record(tx, KAYA_TX_SET_PROPERTY);
    put_u64(tx, id);
    put_u32(tx, KAYA_PROP_TEXT);
    put_u32(tx, KAYA_SOURCE_CONST);
    put_str(tx, text);
    finish(tx, s);
}

static void set_text_element(Tx *tx, uint64_t id, uint32_t level) {
    size_t s = record(tx, KAYA_TX_SET_PROPERTY);
    put_u64(tx, id);
    put_u32(tx, KAYA_PROP_TEXT);
    put_u32(tx, KAYA_SOURCE_ELEMENT);
    put_u32(tx, level);
    put_u32(tx, 0);
    finish(tx, s);
}

static void add_child(Tx *tx, uint64_t parent, uint64_t child) {
    size_t s = record(tx, KAYA_TX_ADD_CHILD);
    put_u64(tx, parent);
    put_u64(tx, child);
    finish(tx, s);
}

static void two_u64(Tx *tx, uint16_t kind, uint64_t a, uint64_t b) {
    size_t s = record(tx, kind);
    put_u64(tx, a);
    put_u64(tx, b);
    finish(tx, s);
}

static void scene_tx(void) {
    Tx tx = {{0}, 0};
    size_t s;

    s = record(&tx, KAYA_TX_CREATE_SIGNAL);
    put_u64(&tx, SIG_STATUS);
    put_str(&tx, "step 0");
    finish(&tx, s);

    s = record(&tx, KAYA_TX_CREATE_SIGNAL);
    put_u64(&tx, SIG_EXTRAS);
    put_bool(&tx, 0);
    finish(&tx, s);

    create_widget(&tx, W_COLUMN, KAYA_KIND_COLUMN);
    create_widget(&tx, W_STEP, KAYA_KIND_BUTTON);
    set_text_const(&tx, W_STEP, "step");
    create_widget(&tx, W_STATUS, KAYA_KIND_LABEL);

    s = record(&tx, KAYA_TX_SET_PROPERTY);
    put_u64(&tx, W_STATUS);
    put_u32(&tx, KAYA_PROP_TEXT);
    put_u32(&tx, KAYA_SOURCE_SIGNAL);
    put_u64(&tx, SIG_STATUS);
    finish(&tx, s);

    /* When(extras): a banner label. The scope brackets the blueprint. */
    two_u64(&tx, KAYA_TX_CREATE_WHEN, W_WHEN, SIG_EXTRAS);
    create_widget(&tx, N_BANNER, KAYA_KIND_LABEL);
    set_text_const(&tx, N_BANNER, "extras on");
    s = record(&tx, KAYA_TX_TEMPLATE_END);
    finish(&tx, s);

    /* For over groups, nesting a For over items. */
    s = record(&tx, KAYA_TX_CREATE_COLLECTION);
    put_u64(&tx, C_GROUPS);
    finish(&tx, s);
    two_u64(&tx, KAYA_TX_CREATE_FOR, W_FOR_GROUPS, C_GROUPS);
    create_widget(&tx, N_GROUP_COL, KAYA_KIND_COLUMN);
    create_widget(&tx, N_GROUP_NAME, KAYA_KIND_LABEL);
    set_text_element(&tx, N_GROUP_NAME, 0);
    add_child(&tx, N_GROUP_COL, N_GROUP_NAME);
    s = record(&tx, KAYA_TX_CREATE_COLLECTION);
    put_u64(&tx, C_ITEMS);
    finish(&tx, s);
    two_u64(&tx, KAYA_TX_CREATE_FOR, N_ITEMS_FOR, C_ITEMS);
    create_widget(&tx, N_ITEM_ROW, KAYA_KIND_COLUMN);
    create_widget(&tx, N_ITEM_TEXT, KAYA_KIND_LABEL);
    set_text_element(&tx, N_ITEM_TEXT, 0);
    create_widget(&tx, N_REMOVE, KAYA_KIND_BUTTON);
    set_text_const(&tx, N_REMOVE, "remove");
    add_child(&tx, N_ITEM_ROW, N_ITEM_TEXT);
    add_child(&tx, N_ITEM_ROW, N_REMOVE);
    s = record(&tx, KAYA_TX_TEMPLATE_END);
    finish(&tx, s);
    add_child(&tx, N_GROUP_COL, N_ITEMS_FOR);
    s = record(&tx, KAYA_TX_TEMPLATE_END);
    finish(&tx, s);

    add_child(&tx, W_COLUMN, W_STEP);
    add_child(&tx, W_COLUMN, W_STATUS);
    add_child(&tx, W_COLUMN, W_WHEN);
    add_child(&tx, W_COLUMN, W_FOR_GROUPS);
    two_u64(&tx, KAYA_TX_MOUNT, 0, W_COLUMN); /* window 0: the default */

    submit(&tx);
}

static void tx_insert(Tx *tx, uint64_t coll, const char *at, const char *key,
                      const char *value) {
    size_t s = record(tx, KAYA_TX_COLLECTION_INSERT);
    put_u64(tx, coll);
    if (at)
        put_path1(tx, at);
    else
        put_path0(tx);
    put_str(tx, key);
    put_str(tx, value);
    finish(tx, s);
}

static void tx_update(Tx *tx, uint64_t coll, const char *key, const char *value) {
    size_t s = record(tx, KAYA_TX_COLLECTION_UPDATE);
    put_u64(tx, coll);
    put_path0(tx);
    put_str(tx, key);
    put_str(tx, value);
    finish(tx, s);
}

static void tx_remove(Tx *tx, uint64_t coll, const char *at, const char *key) {
    size_t s = record(tx, KAYA_TX_COLLECTION_REMOVE);
    put_u64(tx, coll);
    put_path1(tx, at);
    put_str(tx, key);
    finish(tx, s);
}

static void tx_write_str(Tx *tx, uint64_t sig, const char *text) {
    size_t s = record(tx, KAYA_TX_WRITE_SIGNAL);
    put_u64(tx, sig);
    put_str(tx, text);
    finish(tx, s);
}

static void tx_write_bool(Tx *tx, uint64_t sig, int v) {
    size_t s = record(tx, KAYA_TX_WRITE_SIGNAL);
    put_u64(tx, sig);
    put_bool(tx, v);
    finish(tx, s);
}

/* --- Occurrence parsing ------------------------------------------------ */

/* One record: header, u64 id, u32 path_len, u32 pad, then path values. */
static int parse_click(const uint8_t *buf, uint64_t *id, char keys[2][64],
                       uint32_t *nkeys) {
    const KayaRecordButtonClicked *rec = (const KayaRecordButtonClicked *)buf;
    if (rec->header.kind != KAYA_OCCURRENCE_BUTTON_CLICKED)
        return 0;
    *id = rec->id;
    *nkeys = rec->path_len;
    const uint8_t *at = buf + sizeof(KayaRecordButtonClicked);
    for (uint32_t i = 0; i < rec->path_len && i < 2; i++) {
        uint32_t vtype, vlen;
        memcpy(&vtype, at, 4);
        memcpy(&vlen, at + 4, 4);
        if (vtype != KAYA_VALUE_STR || vlen >= 64)
            return 0;
        memcpy(keys[i], at + 8, vlen);
        keys[i][vlen] = 0;
        at += 8 + ((vlen + 7) & ~7u);
    }
    return 1;
}

static void *app(void *arg) {
    (void)arg;
    scene_tx();
    unsigned steps = 0;
    uint8_t buf[256];
    for (;;) {
        size_t size = kaya_next_occurrence(buf, sizeof buf);
        if (size == 0)
            break; /* shutdown */
        uint64_t id;
        char keys[2][64];
        uint32_t nkeys;
        if (!parse_click(buf, &id, keys, &nkeys))
            continue;
        if (nkeys == 0 && id == W_STEP) {
            steps += 1;
            Tx tx = {{0}, 0};
            if (steps == 1) {
                tx_insert(&tx, C_GROUPS, NULL, "g1", "Work");
                tx_insert(&tx, C_ITEMS, "g1", "a", "send report");
                tx_insert(&tx, C_ITEMS, "g1", "b", "buy milk");
            } else if (steps == 2) {
                tx_insert(&tx, C_GROUPS, NULL, "g2", "Home");
                tx_insert(&tx, C_ITEMS, "g2", "a", "water plants");
                tx_update(&tx, C_GROUPS, "g1", "Office");
            }
            char status[32];
            snprintf(status, sizeof status, "step %u", steps);
            tx_write_bool(&tx, SIG_EXTRAS, steps == 1);
            tx_write_str(&tx, SIG_STATUS, status);
            submit(&tx);
        } else if (nkeys == 2 && id == N_REMOVE) {
            Tx tx = {{0}, 0};
            char status[160];
            tx_remove(&tx, C_ITEMS, keys[0], keys[1]);
            snprintf(status, sizeof status, "removed %s/%s", keys[0], keys[1]);
            tx_write_str(&tx, SIG_STATUS, status);
            submit(&tx);
        }
    }
    return NULL;
}

int main(void) {
    pthread_t app_thread;
    pthread_create(&app_thread, NULL, app, NULL);
    return kaya_run(); /* takes over the main thread until the app exits */
}
