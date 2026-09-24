/* The formatter door and the catalog on the C floor (tools/scenes/format.steps,
 * docs/compliance-plan.md §1.4's C row): the explicit buffer shape — ask
 * with cap 0, size, ask again — over kaya_fmt_* and kaya_tr. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h> /* _exit: the app thread cannot return an exit code */

/* Guest-allocated ids (tools/check-c-ids.py). CREATION ORDER IS READ BY
 * THE SCRIPT: labels #0..#10, then row#0 holding label#11, a spacer and
 * label#12, then label#13. */
#define W_COLUMN 1
#define W_LABEL0 2 /* label#0 .. label#10 are W_LABEL0 .. W_LABEL0 + 10 */
#define W_ROW 13
#define W_FIRST 14  /* label#11 */
#define W_SPACER 15 /* a column that grows */
#define W_LAST 16   /* label#12 */
#define W_TAG 17    /* label#13 */

#define SIG_FIRST 1 /* one signal per label, in the same order */

/* Packed by hand: the generated setter closes the record BEFORE the value. */
static void window_prop(KayaTx *tx, uint64_t window, uint32_t prop, KayaVal value) {
    size_t start = kaya_wire_begin(tx, KAYA_TX_SET_WINDOW_PROP);
    kaya_wire_u64(tx, window);
    kaya_wire_u32(tx, prop);
    kaya_wire_u32(tx, KAYA_SOURCE_CONST);
    kaya_wire_value(tx, value);
    kaya_wire_end(tx, start);
}

/* SIZED, THEN READ, and a 0 is the core's fault (its sentence is on
 * stderr), never an empty answer. */
typedef uintptr_t (*door_fn)(void *ctx, uint8_t *out, uintptr_t cap);

static void fill(const char *name, door_fn ask, void *ctx, char *out, size_t cap) {
    uintptr_t needed = ask(ctx, NULL, 0);
    if (needed == 0) {
        fprintf(stderr, "kaya: %s reported a fault\n", name);
        _exit(1);
    }
    if (needed + 1 > cap) {
        fprintf(stderr, "kaya: %s answers %zu bytes and this guest sized %zu\n", name,
                (size_t)needed, cap);
        _exit(1);
    }
    ask(ctx, (uint8_t *)out, needed);
    out[needed] = '\0';
}

struct date_ask { int64_t packed; int64_t length; };
static uintptr_t ask_date(void *ctx, uint8_t *out, uintptr_t cap) {
    struct date_ask *a = ctx;
    return kaya_fmt_date(a->packed, a->length, out, cap);
}
struct time_ask { int64_t packed; int64_t length; };
static uintptr_t ask_time(void *ctx, uint8_t *out, uintptr_t cap) {
    struct time_ask *a = ctx;
    return kaya_fmt_time(a->packed, a->length, out, cap);
}
struct date_time_ask { int64_t date; int64_t time; int64_t length; };
static uintptr_t ask_date_time(void *ctx, uint8_t *out, uintptr_t cap) {
    struct date_time_ask *a = ctx;
    return kaya_fmt_date_time(a->date, a->time, a->length, out, cap);
}
static uintptr_t ask_number(void *ctx, uint8_t *out, uintptr_t cap) {
    return kaya_fmt_number(*(double *)ctx, NULL, out, cap);
}
static uintptr_t ask_percent(void *ctx, uint8_t *out, uintptr_t cap) {
    return kaya_fmt_percent(*(double *)ctx, NULL, out, cap);
}
struct currency_ask { double value; const char *code; };
static uintptr_t ask_currency(void *ctx, uint8_t *out, uintptr_t cap) {
    struct currency_ask *a = ctx;
    return kaya_fmt_currency(a->value, a->code, out, cap);
}
struct tr_ask { const char *key; const KayaTrArg *args; size_t nargs; };
static uintptr_t ask_tr(void *ctx, uint8_t *out, uintptr_t cap) {
    struct tr_ask *a = ctx;
    return kaya_tr(a->key, a->args, a->nargs, out, cap);
}
static uintptr_t ask_locale(void *ctx, uint8_t *out, uintptr_t cap) {
    (void)ctx;
    return kaya_locale(out, cap);
}

static void label(KayaTx *tx, uint64_t widget, uint64_t signal, const char *text) {
    kaya_tx_create_signal(tx, signal, kaya_str(text));
    kaya_tx_create_widget(tx, widget, KAYA_KIND_LABEL);
    kaya_tx_bind_text(tx, widget, signal);
}

static void build_scene(void) {
    uint8_t buf[4096];
    KayaTx tx = {buf, 0, sizeof buf};

    kaya_catalog("format");
    /* 2026-09-07 08:30, packed YYYYMMDD and HHMM. */
    const int64_t date = 20260907;
    const int64_t time = 830;

    char texts[11][256];
    struct date_ask d0 = {date, KAYA_FMT_SHORT};
    fill("kaya_fmt_date", ask_date, &d0, texts[0], sizeof texts[0]);
    struct date_ask d1 = {date, KAYA_FMT_MEDIUM};
    fill("kaya_fmt_date", ask_date, &d1, texts[1], sizeof texts[1]);
    struct date_ask d2 = {date, KAYA_FMT_LONG};
    fill("kaya_fmt_date", ask_date, &d2, texts[2], sizeof texts[2]);
    struct time_ask t3 = {time, KAYA_FMT_SHORT};
    fill("kaya_fmt_time", ask_time, &t3, texts[3], sizeof texts[3]);
    struct date_time_ask dt4 = {date, time, KAYA_FMT_MEDIUM};
    fill("kaya_fmt_date_time", ask_date_time, &dt4, texts[4], sizeof texts[4]);
    double number = 1234567.891;
    fill("kaya_fmt_number", ask_number, &number, texts[5], sizeof texts[5]);
    double fraction = 0.256;
    fill("kaya_fmt_percent", ask_percent, &fraction, texts[6], sizeof texts[6]);
    struct currency_ask c7 = {1234567.89, "USD"};
    fill("kaya_fmt_currency", ask_currency, &c7, texts[7], sizeof texts[7]);
    KayaTrArg one = {"count", KAYA_TR_INT, 1, 0.0, NULL};
    struct tr_ask tr8 = {"items", &one, 1};
    fill("kaya_tr", ask_tr, &tr8, texts[8], sizeof texts[8]);
    KayaTrArg three = {"count", KAYA_TR_INT, 3, 0.0, NULL};
    struct tr_ask tr9 = {"items", &three, 1};
    fill("kaya_tr", ask_tr, &tr9, texts[9], sizeof texts[9]);
    KayaTrArg name = {"name", KAYA_TR_STR, 0, 0.0, "Ada"};
    struct tr_ask tr10 = {"greeting", &name, 1};
    fill("kaya_tr", ask_tr, &tr10, texts[10], sizeof texts[10]);
    char locale_line[256];
    fill("kaya_locale", ask_locale, NULL, locale_line, sizeof locale_line);
    /* The tag is the line's first word. */
    char *space = strchr(locale_line, ' ');
    if (space != NULL)
        *space = '\0';

    /* Fourteen labels and a row: taller than the default window. */
    window_prop(&tx, 0, KAYA_WPROP_TITLE, kaya_str("format"));
    window_prop(&tx, 0, KAYA_WPROP_WIDTH, kaya_f64(540.0));
    window_prop(&tx, 0, KAYA_WPROP_HEIGHT, kaya_f64(560.0));

    kaya_tx_create_widget(&tx, W_COLUMN, KAYA_KIND_COLUMN);
    for (int i = 0; i < 11; i++) {
        label(&tx, W_LABEL0 + i, SIG_FIRST + i, texts[i]);
        kaya_tx_add_child(&tx, W_COLUMN, W_LABEL0 + i);
    }
    kaya_tx_create_widget(&tx, W_ROW, KAYA_KIND_ROW);
    label(&tx, W_FIRST, SIG_FIRST + 11, "first");
    kaya_tx_create_widget(&tx, W_SPACER, KAYA_KIND_COLUMN);
    kaya_tx_set_grow(&tx, W_SPACER, 1.0);
    label(&tx, W_LAST, SIG_FIRST + 12, "last");
    kaya_tx_add_child(&tx, W_ROW, W_FIRST);
    kaya_tx_add_child(&tx, W_ROW, W_SPACER);
    kaya_tx_add_child(&tx, W_ROW, W_LAST);
    kaya_tx_add_child(&tx, W_COLUMN, W_ROW);
    label(&tx, W_TAG, SIG_FIRST + 13, locale_line);
    kaya_tx_add_child(&tx, W_COLUMN, W_TAG);
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
