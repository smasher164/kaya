/* Milestone 1 from C over the C ABI (function floor): the ABI's home
 * language validated the same way as every other guest. The main thread
 * enters kaya_run() and becomes the core's UI thread; a pthread is the
 * app thread, draining occurrences and answering with packed transaction
 * records through kaya_submit. The scene arrives as one transaction; the
 * label's text is a signal binding this guest writes on every click.
 *
 * Built and run by the Linux container suite (tools/linux/run-suites.sh),
 * where a plain cc and the shared library are both at hand. */

#include <kaya.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* Guest-allocated ids, counted from 1 per space. */
#define SIG_TEXT 1
#define W_COLUMN 1
#define W_BUTTON 2
#define W_LABEL 3

/* --- Transaction packing (KAYA_TX_* layouts from kaya.h) ------------- */

typedef struct {
    uint8_t bytes[1024];
    size_t len;
} Tx;

/* Start a record: {u32 size, u16 kind, u16 flags}; the body follows.
 * Returns the record's start for finish(). */
static size_t record(Tx *tx, uint16_t kind) {
    size_t start = tx->len;
    uint32_t size = 0;
    memcpy(tx->bytes + tx->len, &size, 4);
    memcpy(tx->bytes + tx->len + 4, &kind, 2);
    memset(tx->bytes + tx->len + 6, 0, 2);
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

static void put_str(Tx *tx, const char *s) {
    uint32_t len = (uint32_t)strlen(s);
    put_u32(tx, KAYA_VALUE_STR);
    put_u32(tx, len);
    memcpy(tx->bytes + tx->len, s, len);
    tx->len += len;
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

static void scene_tx(void) {
    Tx tx = {0};
    size_t s;

    s = record(&tx, KAYA_TX_CREATE_SIGNAL);
    put_u64(&tx, SIG_TEXT);
    put_str(&tx, "Clicked 0 times");
    finish(&tx, s);

    s = record(&tx, KAYA_TX_CREATE_WIDGET);
    put_u64(&tx, W_COLUMN);
    put_u32(&tx, KAYA_KIND_COLUMN);
    put_u32(&tx, 0);
    finish(&tx, s);

    s = record(&tx, KAYA_TX_CREATE_WIDGET);
    put_u64(&tx, W_BUTTON);
    put_u32(&tx, KAYA_KIND_BUTTON);
    put_u32(&tx, 0);
    finish(&tx, s);

    s = record(&tx, KAYA_TX_SET_PROPERTY);
    put_u64(&tx, W_BUTTON);
    put_u32(&tx, KAYA_PROP_TEXT);
    put_u32(&tx, KAYA_SOURCE_CONST);
    put_str(&tx, "Click me");
    finish(&tx, s);

    s = record(&tx, KAYA_TX_CREATE_WIDGET);
    put_u64(&tx, W_LABEL);
    put_u32(&tx, KAYA_KIND_LABEL);
    put_u32(&tx, 0);
    finish(&tx, s);

    s = record(&tx, KAYA_TX_SET_PROPERTY);
    put_u64(&tx, W_LABEL);
    put_u32(&tx, KAYA_PROP_TEXT);
    put_u32(&tx, KAYA_SOURCE_SIGNAL);
    put_u64(&tx, SIG_TEXT);
    finish(&tx, s);

    s = record(&tx, KAYA_TX_ADD_CHILD);
    put_u64(&tx, W_COLUMN);
    put_u64(&tx, W_BUTTON);
    finish(&tx, s);

    s = record(&tx, KAYA_TX_ADD_CHILD);
    put_u64(&tx, W_COLUMN);
    put_u64(&tx, W_LABEL);
    finish(&tx, s);

    s = record(&tx, KAYA_TX_MOUNT);
    put_u64(&tx, 0); /* window 0: the default */
    put_u64(&tx, W_COLUMN);
    finish(&tx, s);

    submit(&tx);
}

static void write_tx(const char *text) {
    Tx tx = {0};
    size_t s = record(&tx, KAYA_TX_WRITE_SIGNAL);
    put_u64(&tx, SIG_TEXT);
    put_str(&tx, text);
    finish(&tx, s);
    submit(&tx);
}

static void *app(void *arg) {
    (void)arg;
    scene_tx();
    uint64_t count = 0;
    KayaOccurrence occurrence;
    while (kaya_next_occurrence(&occurrence)) {
        if (occurrence.kind == KAYA_OCCURRENCE_BUTTON_CLICKED) {
            char text[64];
            count += 1;
            snprintf(text, sizeof text, "Clicked %llu %s",
                     (unsigned long long)count, count == 1 ? "time" : "times");
            write_tx(text);
        }
    }
    return NULL;
}

int main(void) {
    pthread_t app_thread;
    pthread_create(&app_thread, NULL, app, NULL);
    return kaya_run(); /* takes over the main thread until the app exits */
}
