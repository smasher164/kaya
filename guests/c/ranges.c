/* The text-ranges scene from C, on the function floor: the three
 * primitives an editor cannot write for itself — HIGHLIGHT a set of
 * ranges, SELECT one, REVEAL one — spelled as the three wire records
 * they are (docs/ranges-plan.md D1-D4). Annotated semantics in
 * guests/rust/ranges.rs; the byte-frozen contract in
 * tools/scenes/ranges.steps.
 *
 * THIS FILE IS THE CLEAREST STATEMENT OF THE UNIT RULING, and that is
 * the reason to read the floor here. `at - doc` is a pointer difference
 * into the app's own char buffer: a UTF-8 BYTE offset, arrived at by
 * subtraction, with no conversion table anywhere near it. That integer
 * goes onto the wire unchanged, and every sugar binding is doing the
 * same arithmetic behind a nicer spelling. What converts is the CORE,
 * once, against its own copy of the text, before it lowers anything
 * (scratchpad/ranges-units.md): macOS, iOS, Windows and Android count
 * UTF-16 code units, GTK counts code points, and NO backend ever sees
 * the byte offsets this file computes.
 *
 * THE DOCUMENT OPENS IN JAPANESE FOR EXACTLY THAT REASON. `日本語` is
 * three characters and NINE BYTES, so every match below sits six bytes
 * further along than it sits in UTF-16 — the script asserts 57, where a
 * UTF-16 counter would say 51. A backend that forwarded these offsets
 * unconverted decorates six characters early on every one of them, and
 * the frozen numbers say so rather than the colours looking plausible.
 *
 * THE SEARCH IS strstr, AND THAT IS THE POINT. kaya ships no find
 * engine, no find bar and no regex dialect (docs/ranges-plan.md §3):
 * WHAT to decorate is the app's question and every editor answers it
 * differently. What no app can write for itself is the other half —
 * colouring a run of a native text view, moving its selection,
 * scrolling it into view — and that half is the three records below.
 *
 * WHAT THE SUGAR HIDES AND THIS FILE HAS TO SAY OUT LOUD:
 *   * highlight_ranges carries `count` AND a flat list of 2*count I64
 *     values, start then end. Both are packed by hand here, and the
 *     core asserts they agree — a binding that writes one and means the
 *     other fails loudly instead of painting half a set.
 *   * select_range and reveal_range are their own records rather than
 *     widget_commands, which they otherwise are exactly: that record's
 *     layout has nowhere to put offsets. Down here the three sit within
 *     a few lines of each other and the difference is legible.
 *   * NOTHING IN THIS FILE EVER CLEARS A HIGHLIGHT. D2's drop-on-edit
 *     is a backend invariant, not a message the app sends: a declared
 *     set is bound to the text it was declared against, and the first
 *     keystroke ends it with nothing said. The fold below re-declares
 *     from text_changed, which is the whole of an app's part in it.
 *   * AND NOTHING IN THIS FILE KNOWS ABOUT INPUT METHODS. The select
 *     the last button asks for is REFUSED mid-composition (D4), by the
 *     backend, silently — composition state is on no kaya channel, so
 *     an app cannot avoid the race and is not blamed for asking. This
 *     guest asks in exactly the terms it would at any other moment.
 *
 * Built and run by the mac lane with SCENES=ranges and
 * KAYA_SELFTEST=ranges. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* Guest-allocated ids, counted from 1 per space.
 *
 * THE ORDER BELOW IS CONTRACT, not layout taste: the harness addresses
 * widgets by CREATION order within a kind, and the script names
 * textarea#0, label#0 and button#0..3 = find, reveal last, focus
 * editor, select first. Swapping two buttons would not fail with "no
 * such target" — it would press the wrong one and assert against a
 * selection nobody asked for. */
#define SIG_STATUS 1

#define W_COLUMN 1
#define W_EDITOR 2 /* textarea#0 */
#define W_STATUS 3 /* label#0 */
#define W_ROW 4
#define W_FIND 5   /* button#0 */
#define W_REVEAL 6 /* button#1 */
#define W_FOCUS 7  /* button#2 */
#define W_SELECT 8 /* button#3 */

/* The document, frozen, and byte-identical to the other guests' — the
 * scenes are shared verbatim and the script's offsets are of THESE
 * bytes. Forty short lines, so the last match is far below the
 * viewport and REVEAL has something to do; three occurrences of
 * `alpha` and no other line containing that substring. */
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

/* Room for the app's copy of the document as it grows under the user's
 * typing, and a hit ceiling this scene's three matches sit well inside.
 * The floor sizes its own buffers: kaya_wire packs into caller-owned
 * storage and never checks (bindings/c/kaya_wire.h), so the worst case
 * is arithmetic an author does rather than a length a library guesses.
 * A highlight record is 32 bytes of frame plus 16 per offset value, two
 * values per range — 1056 bytes at MAX_HITS, which is what sizes TX_BUF
 * below. */
#define DOC_CAP 4096
#define MAX_HITS 32
#define TX_BUF 2048

/* THE WHOLE SEARCH: literal, forward, non-overlapping — C's own
 * strstr, walked into a flat array of start,stop pairs, which is the
 * shape the wire wants and therefore no shape at all.
 *
 * `at - doc` IS THE OFFSET, and there is nothing else to it: a byte
 * count from the start of the app's buffer, which is kaya's unit on
 * every binding and every platform. An editor that wants case folding,
 * word boundaries or a regex dialect writes those here, in the app,
 * where its users can be told what they mean. */
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

/* A Str window prop, packed out: {u64 window, u32 prop, u32 source,
 * value}. The generated kaya_tx_set_window_prop closes the record
 * BEFORE the value — the tail convention it shares with SET_PROPERTY —
 * so a caller with a value to write begins the record itself, which is
 * what every C guest's title does (guests/c/dirty.c). */
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
    /* The editor, seeded with the document the app opened. The
     * accessibility id is not decoration: every range assertion in the
     * script reads the PLATFORM'S accessibility tree — the attributed
     * string's background runs, the selected range, the visible range —
     * and this id is how a leg finds this control there. */
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

    /* THE APP'S OWN COPY OF THE DOCUMENT, and the only authority on
     * what an offset means. kaya never hands a widget's text back on
     * request — there are no widget mirror reads — so the field owns
     * its text, reports each edit as a text_changed occurrence, and the
     * app folds those into this buffer, exactly as the entry scene's
     * draft does. The offsets below are offsets into THIS. */
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
            /* The floor's own bound on a document it did not size. A
             * copy cut short cannot find what is past the cut, but the
             * offsets it does find are still the right ones: a prefix
             * preserves byte offsets, which is a property this unit has
             * and no other unit here does. And an offset that landed
             * inside a character would not be lowered anywhere — the
             * core refuses a range whose endpoint is off a code-point
             * boundary, naming the character it splits, because the five
             * platforms answer a malformed one in four different ways
             * and one of them aborts the process. */
            size_t len = text.s_len < DOC_CAP ? text.s_len : DOC_CAP - 1;
            memcpy(doc, text.s, len);
            doc[len] = '\0';
            /* THE SEARCH RESULTS ARE STALE AND THE APP SAYS SO. kaya
             * has already dropped the decorations — that is D2, and it
             * happened in the backend without a word to anyone — and
             * this is the app agreeing rather than being told: an
             * editor whose document moved has to search again before it
             * can claim anything about where the matches are. */
            KayaTx tx = {buf, 0};
            kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str("0 matches"));
            kaya_submit(tx.buf, tx.len);
        } else if (kaya_parse_click(rec, &id, keys, 2, &n_keys)) {
            if (n_keys != 0)
                continue;
            if (id == W_FIND) {
                uint32_t n = find_all(doc, NEEDLE, flat, MAX_HITS);
                KayaTx tx = {buf, 0};
                /* THE SET, DECLARED IN ONE RECORD. `count` is the
                 * number of RANGES and the values list is 2*count
                 * OFFSETS — start, stop, start, stop — and the two are
                 * written a line apart here because the record has them
                 * a field apart. An empty set is the clear; this app
                 * never sends one, because an edit already dropped
                 * whatever was declared. */
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
                /* A PURE EFFECT: the viewport moves and nothing else
                 * does. The declared set is still declared, the
                 * selection has not moved, and undo does not put the
                 * scroll back (docs/undo-plan.md A2) — the script
                 * asserts all three after this click. */
                KayaTx tx = {buf, 0};
                kaya_tx_reveal_range(&tx, W_EDITOR, flat[2 * (n - 1)],
                                     flat[2 * (n - 1) + 1]);
                kaya_submit(tx.buf, tx.len);
            } else if (id == W_FOCUS) {
                /* The keyboard, moved by the one-shot command record
                 * that has always done it — no offsets, nothing at
                 * rest. The script types into the editor next, and a
                 * keystroke has to land somewhere. */
                KayaTx tx = {buf, 0};
                kaya_tx_widget_command(&tx, W_EDITOR, KAYA_COMMAND_FOCUS);
                kaya_submit(tx.buf, tx.len);
            } else if (id == W_SELECT) {
                uint32_t n = find_all(doc, NEEDLE, flat, MAX_HITS);
                if (n == 0)
                    continue;
                /* THE FIRST MATCH — asked for in the ordinary way, and
                 * refused by the backend because the user is composing
                 * (D4). Nothing here tests for that and nothing here
                 * could: an input method's marked text reaches no kaya
                 * channel, so the same two lines are honoured one
                 * millisecond and dropped the next. The app that wants
                 * the selection asks again after the next text_changed,
                 * which is what ends a composition. */
                KayaTx tx = {buf, 0};
                kaya_tx_select_range(&tx, W_EDITOR, flat[0], flat[1]);
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
