/* The assets conformance scene from C, on the function floor: the whole
 * asset surface written longhand (docs/assets-plan.md).
 *
 * ZERO IS THE MISS, NEVER A PANIC — kaya_asset_open answers 0 and
 * kaya_asset_why_not says why, because a panic inside an `extern "C"`
 * frame is an uncatchable abort in every guest.
 *
 * Contract: tools/scenes/assets.steps. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h> /* _exit: the app thread cannot return an exit code */

/* Guest-allocated ids, counted from 1 per space. CREATION ORDER IS READ
 * BY THE SCRIPT: label#0 is the title, image#0 the mark, label#1 the
 * miss sentence's first line, label#2 the font's size. */
#define SIG_TITLE 1
#define SIG_CENSUS 2
#define SIG_SIZES 3

#define W_COLUMN 1
#define W_TITLE 2  /* label#0 */
#define W_MARK 3   /* image#0 */
#define W_CENSUS 4 /* label#1 */
#define W_SIZES 5  /* label#2 */

/* The asset that is deliberately not there: a LEGAL name — relative,
 * `/`-spelled, one component deep — so the sentence under test is the
 * census one and not a name-fault one. */
static const char MISSING[] = "icons/nope.png";
static const char MARK[] = "icons/kaya-mark.png";
static const char FONT[] = "fonts/sora-wght.ttf";

/* A window prop with its value, packed by hand: the generated
 * kaya_tx_set_window_prop closes the record BEFORE the value. */
static void window_prop(KayaTx *tx, uint64_t window, uint32_t prop, KayaVal value) {
    size_t start = kaya_wire_begin(tx, KAYA_TX_SET_WINDOW_PROP);
    kaya_wire_u64(tx, window);
    kaya_wire_u32(tx, prop);
    kaya_wire_u32(tx, KAYA_SOURCE_CONST);
    kaya_wire_value(tx, value);
    kaya_wire_end(tx, start);
}

/* Open an asset or die naming the CORE's own sentence: there is one
 * author for the diagnostic, so the bytes a C guest prints and the
 * bytes a Haskell guest raises are the same. */
static uint64_t open_or_die(const char *name);

/* SIZED, THEN READ: the first call passes a NULL buffer and cap 0 and
 * returns the sentence's TRUE length, the second fills a buffer of that
 * size. A guessed buffer cuts the half naming the root and the route,
 * so a sentence that does not fit is a hard error rather than a quiet
 * truncation. */
static void why_not(const char *name, char *out, size_t cap) {
    size_t needed = kaya_asset_why_not((const uint8_t *)name, strlen(name), NULL, 0);
    if (needed + 1 > cap) {
        fprintf(stderr,
                "kaya: the asset diagnostic for \"%s\" is %zu bytes and this "
                "guest sized %zu — a truncated sentence still looks like a "
                "sentence, so it is refused here\n",
                name, needed, cap);
        _exit(1);
    }
    if (needed > 0)
        kaya_asset_why_not((const uint8_t *)name, strlen(name), (uint8_t *)out, needed);
    out[needed] = '\0';
    /* LINE 1 ONLY: line 2 names the resolved place and the route that
     * chose it, which a bundle, a device directory and a repo checkout
     * spell three different ways. */
    char *newline = strchr(out, '\n');
    if (newline != NULL)
        *newline = '\0';
}

static uint64_t open_or_die(const char *name) {
    uint64_t handle = kaya_asset_open((const uint8_t *)name, strlen(name));
    if (handle == 0) {
        char sentence[1024];
        why_not(name, sentence, sizeof sentence);
        fprintf(stderr, "%s\n", sentence);
        _exit(1);
    }
    return handle;
}

static void build_scene(void) {
    uint8_t buf[2048];
    KayaTx tx = {buf, 0};

    window_prop(&tx, 0, KAYA_WPROP_TITLE, kaya_str("assets"));
    window_prop(&tx, 0, KAYA_WPROP_WIDTH, kaya_f64(480.0));
    window_prop(&tx, 0, KAYA_WPROP_HEIGHT, kaya_f64(360.0));

    uint64_t mark = open_or_die(MARK);
    uint64_t font = open_or_die(FONT);

    /* THE BLOB REDEMPTION: kaya_tx_set_source takes exactly the handle
     * kaya_asset_blob mints, and the Arc is cloned rather than the
     * bytes. The registration is valid for exactly ONE submit, drained
     * whether referenced or not, so it happens inside the transaction
     * that mounts. */
    uint64_t mark_blob = kaya_asset_blob(mark);

    /* THE BYTES REDEMPTION: the pointer borrows core memory and stays
     * valid until the release below — copy, then release. */
    uintptr_t font_len = 0;
    const uint8_t *font_bytes = kaya_asset_bytes(font, &font_len);
    if (font_bytes == NULL) {
        fprintf(stderr, "kaya: the font asset opened and then had no bytes\n");
        return;
    }

    char census[1024];
    why_not(MISSING, census, sizeof census);

    char complaint[1024];
    why_not(FONT, complaint, sizeof complaint);
    char sizes[1152];
    snprintf(sizes, sizeof sizes, "%s: %zu bytes, %s", FONT, (size_t)font_len,
             complaint[0] == '\0' ? "no complaint" : complaint);

    kaya_tx_create_signal(&tx, SIG_TITLE, kaya_str("assets"));
    kaya_tx_create_signal(&tx, SIG_CENSUS, kaya_str(census));
    kaya_tx_create_signal(&tx, SIG_SIZES, kaya_str(sizes));

    kaya_tx_create_widget(&tx, W_COLUMN, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, W_TITLE, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_TITLE, SIG_TITLE);
    kaya_tx_create_widget(&tx, W_MARK, KAYA_KIND_IMAGE);
    kaya_tx_set_source(&tx, W_MARK, mark_blob);
    kaya_tx_create_widget(&tx, W_CENSUS, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_CENSUS, SIG_CENSUS);
    kaya_tx_create_widget(&tx, W_SIZES, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_SIZES, SIG_SIZES);

    kaya_tx_add_child(&tx, W_COLUMN, W_TITLE);
    kaya_tx_add_child(&tx, W_COLUMN, W_MARK);
    kaya_tx_add_child(&tx, W_COLUMN, W_CENSUS);
    kaya_tx_add_child(&tx, W_COLUMN, W_SIZES);
    kaya_tx_mount(&tx, 0, W_COLUMN); /* window 0: the default */

    kaya_submit(tx.buf, tx.len);

    kaya_asset_release(mark);
    kaya_asset_release(font);
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
