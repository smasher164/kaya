/* The text-ranges scene from C, on the function floor: HIGHLIGHT a set
 * of ranges, SELECT one, REVEAL one, spelled as the three wire records
 * they are (docs/ranges-plan.md D1-D4). Annotated semantics in
 * guests/rust/ranges.rs; the byte-frozen contract in
 * tools/scenes/ranges.steps.
 *
 * EVERY OFFSET HERE IS A UTF-8 BYTE OFFSET into the app's own buffer,
 * and it goes onto the wire unchanged: the CORE converts, once, against
 * its own copy of the text (macOS/iOS/Windows/Android count UTF-16 code
 * units, GTK counts code points). The document opens in Japanese so the
 * frozen numbers catch a backend that forwards them unconverted —
 * `日本語` is three characters and NINE BYTES, so the script's 57 would
 * be 51 to a UTF-16 counter.
 *
 * NOTHING IN THIS FILE EVER CLEARS A HIGHLIGHT: D2's drop-on-edit is a
 * backend invariant, not a message. And nothing here knows about input
 * methods — the select is REFUSED mid-composition (D4), silently, by
 * the backend, and composition state is on no kaya channel.
 *
 * Built and run by the mac lane with SCENES=ranges and
 * KAYA_SELFTEST=ranges. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* Guest-allocated ids, counted from 1 per space. CREATION ORDER IS
 * CONTRACT: the script names textarea#0, label#0 and button#0..3 = find,
 * reveal last, focus editor, select first. Swapping two buttons presses
 * the wrong one rather than failing. */
#define SIG_STATUS 1

#define W_COLUMN 1
#define W_EDITOR 2 /* textarea#0 */
#define W_STATUS 3 /* label#0 */
#define W_ROW 4
#define W_FIND 5   /* button#0 */
#define W_REVEAL 6 /* button#1 */
#define W_FOCUS 7  /* button#2 */
#define W_SELECT 8 /* button#3 */

/* The document, frozen and byte-identical to the other guests': the
 * script's offsets are of THESE bytes. Forty short lines, so the last
 * match is below the viewport and REVEAL has something to do; three
 * occurrences of `alpha` and no other line containing it. */
static const char DOC[] =
    "line 00: 日本語 preface\n"
    "line 01: gamma kappa\n"
    "line 02: alpha beta gamma\n"
    "line 03: epsilon theta\n"
    "line 04: zeta nu\n"
    "line 05: eta zeta\n"
    "line 06: theta lambda\n"
    "line 07: iota delta\n"
    "line 08: kappa iota\n"
    "line 09: alpha eta theta\n"
    "line 10: mu eta\n"
    "line 11: nu mu\n"
    "line 12: beta epsilon\n"
    "line 13: gamma kappa\n"
    "line 14: delta gamma\n"
    "line 15: epsilon theta\n"
    "line 16: zeta nu\n"
    "line 17: eta zeta\n"
    "line 18: theta lambda\n"
    "line 19: iota delta\n"
    "line 20: kappa iota\n"
    "line 21: lambda beta\n"
    "line 22: mu eta\n"
    "line 23: nu mu\n"
    "line 24: beta epsilon\n"
    "line 25: gamma kappa\n"
    "line 26: delta gamma\n"
    "line 27: epsilon theta\n"
    "line 28: zeta nu\n"
    "line 29: eta zeta\n"
    "line 30: theta lambda\n"
    "line 31: iota delta\n"
    "line 32: kappa iota\n"
    "line 33: lambda beta\n"
    "line 34: mu eta\n"
    "line 35: nu mu\n"
    "line 36: beta epsilon\n"
    "line 37: alpha iota kappa\n"
    "line 38: delta gamma\n"
    "line 39: the last line";

static const char NEEDLE[] = "alpha";

/* The floor sizes its own buffers: kaya_wire packs into caller-owned
 * storage and never checks (bindings/c/kaya_wire.h). A highlight record
 * is 32 bytes of frame plus 16 per offset value, two values per range —
 * 1056 bytes at MAX_HITS, which is what sizes TX_BUF. */
#define DOC_CAP 4096
#define MAX_HITS 32
#define TX_BUF 2048

/* The whole search: literal, forward, non-overlapping, walked into the
 * flat start,stop array the wire wants. kaya ships no find engine — WHAT
 * to decorate is the app's question (docs/ranges-plan.md §3). */
static uint32_t find_all(const char *doc, const char *needle, uint64_t *flat,
                         uint32_t max) {
    size_t len = strlen(needle);
    uint32_t n = 0;
    for (const char *at = strstr(doc, needle); at != NULL && n < max;
         at = strstr(at + len, needle)) {
        flat[2 * n] = (uint64_t)(at - doc);
        flat[2 * n + 1] = (uint64_t)(at - doc) + len;
        n += 1;
    }
    return n;
}

/* A Str window prop, packed by hand: the generated
 * kaya_tx_set_window_prop closes the record BEFORE the value. */
static void window_title(KayaTx *tx, uint64_t window, const char *title) {
    size_t start = kaya_wire_begin(tx, KAYA_TX_SET_WINDOW_PROP);
    kaya_wire_u64(tx, window);
    kaya_wire_u32(tx, KAYA_WPROP_TITLE);
    kaya_wire_u32(tx, KAYA_SOURCE_CONST);
    kaya_wire_value(tx, kaya_str(title));
    kaya_wire_end(tx, start);
}

static void build_scene(void) {
    uint8_t buf[2048];
    KayaTx tx = {buf, 0};

    window_title(&tx, 0, "ranges");
    kaya_tx_create_signal(&tx, SIG_STATUS, kaya_str("0 matches"));

    kaya_tx_create_widget(&tx, W_COLUMN, KAYA_KIND_COLUMN);
    /* The a11y id is not decoration: every range assertion reads the
     * PLATFORM'S accessibility tree, and this is how a leg finds this
     * control there. */
    kaya_tx_create_widget(&tx, W_EDITOR, KAYA_KIND_TEXTAREA);
    kaya_tx_set_a11y_id(&tx, W_EDITOR, "doc");
    kaya_tx_set_a11y_label(&tx, W_EDITOR, "Document");
    kaya_tx_set_text(&tx, W_EDITOR, DOC);

    kaya_tx_create_widget(&tx, W_STATUS, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_STATUS, SIG_STATUS);

    kaya_tx_create_widget(&tx, W_ROW, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, W_FIND, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_FIND, "find");
    kaya_tx_create_widget(&tx, W_REVEAL, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_REVEAL, "reveal last");
    kaya_tx_create_widget(&tx, W_FOCUS, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_FOCUS, "focus editor");
    kaya_tx_create_widget(&tx, W_SELECT, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_SELECT, "select first");

    kaya_tx_add_child(&tx, W_ROW, W_FIND);
    kaya_tx_add_child(&tx, W_ROW, W_REVEAL);
    kaya_tx_add_child(&tx, W_ROW, W_FOCUS);
    kaya_tx_add_child(&tx, W_ROW, W_SELECT);

    kaya_tx_add_child(&tx, W_COLUMN, W_EDITOR);
    kaya_tx_add_child(&tx, W_COLUMN, W_STATUS);
    kaya_tx_add_child(&tx, W_COLUMN, W_ROW);
    kaya_tx_mount(&tx, 0, W_COLUMN); /* window 0: the default */

    kaya_submit(tx.buf, tx.len);
}

static void *app(void *arg) {
    (void)arg;
    build_scene();

    /* THE APP'S OWN COPY, and the only authority on what an offset
     * means: kaya never hands a widget's text back on request, so the
     * app folds text_changed into this buffer. */
    char doc[DOC_CAP];
    memcpy(doc, DOC, sizeof DOC); /* the literal's NUL comes along */

    const uint8_t *rec;
    for (;;) {
        size_t size = kaya_next_occurrence(&rec);
        if (size == 0)
            break; /* shutdown */
        if (size == KAYA_OCCURRENCE_WOKEN)
            continue; /* no record; rec is NULL */
        uint64_t id;
        KayaVal keys[2], text;
        uint32_t n_keys;
        uint8_t buf[TX_BUF];
        uint64_t flat[2 * MAX_HITS];
        if (kaya_parse_text_changed(rec, &id, keys, 2, &n_keys, &text)) {
            if (id != W_EDITOR || n_keys != 0)
                continue;
            /* Truncating is safe for the offsets that survive: a prefix
             * preserves byte offsets. An offset landing INSIDE a
             * character is refused by the core, naming the character it
             * splits — the five platforms answer a malformed range four
             * different ways and one of them aborts. */
            size_t len = text.s_len < DOC_CAP ? text.s_len : DOC_CAP - 1;
            memcpy(doc, text.s, len);
            doc[len] = '\0';
            /* The backend has already dropped the decorations (D2),
             * silently; this is the app agreeing rather than being
             * told. */
            KayaTx tx = {buf, 0};
            kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str("0 matches"));
            kaya_submit(tx.buf, tx.len);
        } else if (kaya_parse_click(rec, &id, keys, 2, &n_keys)) {
            if (n_keys != 0)
                continue;
            if (id == W_FIND) {
                uint32_t n = find_all(doc, NEEDLE, flat, MAX_HITS);
                KayaTx tx = {buf, 0};
                /* `count` is the number of RANGES and the values list is
                 * 2*count OFFSETS; the core asserts the two agree. An
                 * empty set is the clear, which this app never sends. */
                KayaVal ranges[2 * MAX_HITS];
                for (uint32_t i = 0; i < 2 * n; i++)
                    ranges[i] = kaya_i64((int64_t)flat[i]);
                kaya_tx_highlight_ranges(&tx, W_EDITOR, n, ranges, 2 * n);
                /* The SECOND match, so a leg can tell the selection
                 * apart from "the first thing the search found". */
                if (n > 1)
                    kaya_tx_select_range(&tx, W_EDITOR, flat[2], flat[3]);
                char status[32];
                snprintf(status, sizeof status, "%u matches", n);
                kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str(status));
                kaya_submit(tx.buf, tx.len);
            } else if (id == W_REVEAL) {
                uint32_t n = find_all(doc, NEEDLE, flat, MAX_HITS);
                if (n == 0)
                    continue;
                /* A PURE EFFECT: the viewport moves, the declared set
                 * and the selection do not, and undo does not put the
                 * scroll back (docs/undo-plan.md A2). */
                KayaTx tx = {buf, 0};
                kaya_tx_reveal_range(&tx, W_EDITOR, flat[2 * (n - 1)],
                                     flat[2 * (n - 1) + 1]);
                kaya_submit(tx.buf, tx.len);
            } else if (id == W_FOCUS) {
                /* The script types into the editor next, and a keystroke
                 * has to land somewhere. */
                KayaTx tx = {buf, 0};
                kaya_tx_widget_command(&tx, W_EDITOR, KAYA_COMMAND_FOCUS);
                kaya_submit(tx.buf, tx.len);
            } else if (id == W_SELECT) {
                uint32_t n = find_all(doc, NEEDLE, flat, MAX_HITS);
                if (n == 0)
                    continue;
                /* The first match, asked for in the ordinary way and
                 * refused mid-composition (D4). Nothing here could test
                 * for that; an app that wants the selection asks again
                 * after the next text_changed, which ends a
                 * composition. */
                KayaTx tx = {buf, 0};
                kaya_tx_select_range(&tx, W_EDITOR, flat[0], flat[1]);
                kaya_submit(tx.buf, tx.len);
            }
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
