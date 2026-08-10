/* The save scene from C, at the explicit wire floor: the save request
 * declared as the record it IS, and the answer to BOTH dialogs decoded
 * by hand out of the one occurrence they share (docs/save-plan.md
 * D1-D5). Annotated semantics in guests/rust/save.rs; the byte-frozen
 * contract in tools/scenes/save.steps.
 *
 * WHAT THE SCENE PROVES, and none of it is about a dialog closing:
 * save-back through the handle the OPEN picker handed over; a save
 * destination being openable AT ALL; the two files staying different;
 * and cancel being nothing, with the dialog id retiring so a second
 * dialog can show.
 *
 * THE FLOOR'S THREE JOBS HERE, each of which a sugar binding hides:
 *
 * 1. THE REQUEST IS A RECORD. `tx.save_file("copy")` in the eight
 *    bindings is kaya_tx_show_save_dialog down here — window, a
 *    guest-chosen dialog id, the suggested name, and a filter list this
 *    guest deliberately leaves EMPTY. It sits three lines from
 *    kaya_tx_show_file_dialog, so D2's "the same request/result grammar
 *    as the open picker" is a thing you can read rather than a claim.
 *
 * 2. ONE ANSWER RECORD SERVES BOTH REQUESTS, and the guest is what
 *    tells them apart. The sugar languages spell two callbacks
 *    (`on_files` and `on_saved`) and the difference looks like a type;
 *    on the wire there is one occurrence, KAYA_OCCURRENCE_FILE_DIALOG_
 *    RESULT, carrying the dialog id the guest itself chose. That is
 *    WHY the ids are the guest's: they are the only thing that says
 *    which question this is the answer to. This file keeps the two ids
 *    it minted and matches on them, which is exactly the bookkeeping
 *    those bindings do before they pick a callback.
 *
 *    AND CANCEL IS COUNT ZERO, for both, identically — no platform can
 *    confirm an empty selection, and a save panel that names nothing
 *    reports the same emptiness a picker does. Nothing is remembered
 *    for it: the destination stays absent and the next save-as asks
 *    again.
 *
 * 3. REDEEM A HANDLE, THEN WRITE. `kaya_open_picked` turns the I64 the
 *    result carried into a real descriptor, and from there it is
 *    write(2), close(2) and read(2) — the core is nowhere in the data
 *    path, which is the whole claim the file-dialog design makes. The
 *    handle is redeemed AGAIN for the read-back rather than the
 *    descriptor being rewound, because that is what a second `open` on
 *    a picked file means on every platform and it is what the other
 *    eight guests do.
 *
 * THE CREATE IS THE CORE'S AND THERE IS NOTHING HERE TO ASK FOR IT.
 * A save panel answers with a name for a file NOBODY HAS MADE
 * (measured on macOS: `exists=false` after a clean Save), so opening a
 * destination would fail with ENOENT for a file the user just named.
 * D1 puts the create-and-truncate on the DESTINATION rather than on a
 * fourth file mode, so this guest passes FILE_MODE_WRITE for the
 * save-back and for the save-as alike and the two behave differently
 * because the SOURCES differ, not because the request did. There is no
 * FILE_MODE_CREATE to reach for — deliberately, since a mode would let
 * a guest ask for creation on a file it merely opened, which is how
 * "save" quietly becomes "clobber".
 *
 * EVERY STATUS IS A READ-BACK OFF THE DISK. This guest never reports
 * what it hoped it wrote: each string is the file reopened through the
 * handle kaya gave it and read with ordinary POSIX calls. A write that
 * returned success and landed nowhere is exactly the failure "save"
 * has, and only reopening can see it.
 *
 * THE FILE IS READ THROUGH THE HANDLE, NEVER THROUGH `local_path`. The
 * result record carries that string and this file decodes it and then
 * touches it exactly once, to say so: it is empty on both phones, so a
 * port that reached for it would pass on the desktops and be
 * unportable by construction.
 *
 * THE WORK RUNS OFF THE APP THREAD, because `kaya_open_picked` blocks
 * and a cloud provider may download the whole file first. The floor
 * owns the queue-plus-wake that a binding's `post` hides, and it is
 * written out at length in guests/c/background.c — this file uses the
 * same three pieces (a mutex-guarded slot, kaya_wake, a drain at the
 * top of the loop) without repeating the lesson.
 *
 * NO EXTENSIONS ON ANY NAME, deliberately. A save panel publishes its
 * name field with the extension hidden when the user's Finder
 * preference says so, which would make `expect_save_dialog` read the
 * stem on one machine and the whole name on another. A name with no
 * extension has no stem to differ from.
 *
 * Built and run by the mac lane and the Linux container suite with
 * KAYA_SELFTEST=save. */

#include <kaya.h>
#include <kaya_wire.h>

#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* Guest-allocated ids, counted from 1 per space.
 *
 * THE ORDER BELOW IS CONTRACT, not layout taste: the harness addresses
 * widgets by CREATION order within a kind, and the script names
 * label#0 and button#0..3 = open, save, save as, reopen. Swapping two
 * buttons would not fail with "no such target" — it would press the
 * wrong one and assert against a file nobody asked for. */
#define SIG_STATUS 1

#define W_COLUMN 1
#define W_STATUS 2  /* label#0 */
#define W_OPEN 3    /* button#0 */
#define W_SAVE 4    /* button#1 */
#define W_SAVE_AS 5 /* button#2 */
#define W_REOPEN 6  /* button#3 */

/* ---------------------------------------------------------------- */
/* The scene's own files, written before anything is shown.          */
/* ---------------------------------------------------------------- */

/* Both halves of the process compute this directory, and they must
 * agree with no runner involvement: the guest writes the files, the
 * interpreter aims the panel with `file_dialog_goto $TMP/kaya-save-
 * $PID`, and $TMP is whatever THAT half's language calls the temp
 * directory. C's way is `TMPDIR` or "/tmp", which is what the SwiftUI
 * interpreter's kayaTempDir() and Rust's std::env::temp_dir() both
 * compute — NOT Darwin's per-user directory, which ignores TMPDIR and
 * disagrees with every guest under `nix develop` (docs/traps.md).
 *
 * The pid keeps parallel legs from colliding, and the script names only
 * BASENAMES so one file serves five lanes whose temp directories
 * differ. */
static char scene_dir[512];

static void write_scene_file(const char *name, const char *bytes) {
    char path[600];
    snprintf(path, sizeof path, "%s/%s", scene_dir, name);
    FILE *f = fopen(path, "wb");
    if (f == NULL) {
        fprintf(stderr, "save: cannot write %s: %s\n", path, strerror(errno));
        exit(1);
    }
    fwrite(bytes, 1, strlen(bytes), f);
    fclose(f);
}

static void make_scene_files(void) {
    const char *tmp = getenv("TMPDIR");
    if (tmp == NULL || tmp[0] == '\0')
        tmp = "/tmp";
    /* Trailing separators trimmed for the same reason the harness's own
     * expander trims them: a temp directory that ends in '/' and a
     * scene path that starts with one make "…//kaya-save-N", which
     * POSIX shrugs at and a parsing name elsewhere does not. */
    size_t len = strlen(tmp);
    while (len > 1 && tmp[len - 1] == '/')
        len--;
    snprintf(scene_dir, sizeof scene_dir, "%.*s/kaya-save-%ld", (int)len, tmp,
             (long)getpid());
    if (mkdir(scene_dir, 0700) != 0 && errno != EEXIST) {
        fprintf(stderr, "save: cannot make %s: %s\n", scene_dir, strerror(errno));
        exit(1);
    }
    /* The file the scene opens, plus the decoy the picker needs: with
     * ONE file in the directory a dialog completes with it when nothing
     * is selected, so `file_choose` would pass on a backend that never
     * selected anything. "decoy" sorts FIRST, so that backend gets the
     * WRONG file and its five bytes fail the byte assertion too. */
    write_scene_file("draft", "first draft");
    write_scene_file("decoy", "decoy");
}

/* ---------------------------------------------------------------- */
/* Redeeming a handle: the sequence the sugar languages hide.        */
/* ---------------------------------------------------------------- */

/* Read a handle back through kaya, with the guest's own file API. THE
 * READ-BACK IS THE ASSERTION in every step of this scene.
 *
 * `kaya_open_picked` is one of the two entries in the whole C API that
 * is safe from any thread (kaya_wake is the other), which is what lets
 * the worker below call it at all. It answers 0, or a POSITIVE errno —
 * the platform's own answer, which kaya passes through rather than
 * standing between the guest and the error. */
static void read_back(uint64_t handle, char *out, size_t cap) {
    int64_t raw;
    uint32_t seekable;
    int rc = kaya_open_picked(handle, FILE_MODE_READ, &raw, &seekable);
    if (rc != 0) {
        snprintf(out, cap, "open failed: %s", strerror(rc));
        return;
    }
    int fd = (int)raw;
    size_t at = 0;
    while (at + 1 < cap) {
        ssize_t n = read(fd, out + at, cap - 1 - at);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            snprintf(out, cap, "read failed: %s", strerror(errno));
            close(fd);
            return;
        }
        if (n == 0)
            break;
        at += (size_t)n;
    }
    out[at] = 0;
    close(fd);
}

/* Write `bytes` through a handle and report what the file says
 * afterwards. FILE_MODE_WRITE truncates, on a picked file and on a save
 * destination alike — the destination only adds the create (D1). */
static void write_back(uint64_t handle, const char *bytes, char *out, size_t cap) {
    int64_t raw;
    uint32_t seekable;
    int rc = kaya_open_picked(handle, FILE_MODE_WRITE, &raw, &seekable);
    if (rc != 0) {
        /* THE FAILURE D1 EXISTS TO PREVENT reaches the label verbatim:
         * without the create, a save destination answers "No such file
         * or directory" right here, for a file the user just named. */
        snprintf(out, cap, "save failed: %s", strerror(rc));
        return;
    }
    int fd = (int)raw;
    size_t len = strlen(bytes), at = 0;
    while (at < len) {
        ssize_t n = write(fd, bytes + at, len - at);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            snprintf(out, cap, "write failed: %s", strerror(errno));
            close(fd);
            return;
        }
        at += (size_t)n;
    }
    /* CLOSED BEFORE THE REOPEN, so the bytes read back are the FILE's
     * and not this descriptor's. */
    close(fd);
    read_back(handle, out, cap);
}

/* ---------------------------------------------------------------- */
/* Off the app thread, and back: the floor's own post queue.         */
/* ---------------------------------------------------------------- */

/* The queue a sugar binding keeps privately, one status write wide,
 * because that is all this scene ever posts. The mechanism is written
 * out at length in guests/c/background.c — a mutex-guarded list,
 * kaya_wake to ring the app thread, and a drain at the TOP of the
 * occurrence loop so that whatever brought the thread back, it looks
 * here first. */
#define MAX_POSTED 4
#define STATUS_CAP 600
static pthread_mutex_t post_lock = PTHREAD_MUTEX_INITIALIZER;
static char posted[MAX_POSTED][STATUS_CAP];
static unsigned posted_count = 0;

static void post_status(const char *text) {
    pthread_mutex_lock(&post_lock);
    if (posted_count < MAX_POSTED)
        snprintf(posted[posted_count++], STATUS_CAP, "%s", text);
    pthread_mutex_unlock(&post_lock);
    /* The app thread is parked in kaya_next_occurrence. Posted work is
     * not an occurrence and never enters the ring, so this is the only
     * way it hears about it. */
    kaya_wake();
}

static void drain_posted(void) {
    char batch[MAX_POSTED][STATUS_CAP];
    unsigned n;
    pthread_mutex_lock(&post_lock);
    n = posted_count;
    memcpy(batch, posted, sizeof batch);
    posted_count = 0;
    pthread_mutex_unlock(&post_lock);
    if (n == 0)
        return;
    uint8_t buf[4096];
    KayaTx tx = {buf, 0};
    for (unsigned i = 0; i < n; i++)
        kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str(batch[i]));
    kaya_submit(tx.buf, tx.len);
}

/* One file operation, described as DATA rather than as a closure —
 * closures do not cross the C ABI, so the floor spells each job's
 * destination the way background.c spells each queued write's.
 *
 * `bytes` NULL is a pure read; `second` non-zero adds a second handle to
 * read after the first, which is the reopen step and the only one that
 * names two. */
typedef struct {
    char prefix[16];
    uint64_t first;
    uint64_t second;
    const char *bytes;
} SaveJob;

static void *worker(void *arg) {
    SaveJob *job = arg;
    char first[STATUS_CAP], second[STATUS_CAP], text[STATUS_CAP];
    if (job->bytes != NULL)
        write_back(job->first, job->bytes, first, sizeof first);
    else
        read_back(job->first, first, sizeof first);
    if (job->second != 0) {
        read_back(job->second, second, sizeof second);
        snprintf(text, sizeof text, "%s %s %s", job->prefix, first, second);
    } else {
        snprintf(text, sizeof text, "%s %s", job->prefix, first);
    }
    post_status(text);
    free(job);
    return NULL;
}

/* Start one job on a thread of the guest's own. Detached, because
 * nothing joins it: the answer comes back through the queue above, and
 * kaya supplies no waiting primitive (and should not). */
static void work(const char *prefix, uint64_t first, uint64_t second,
                 const char *bytes) {
    SaveJob *job = malloc(sizeof *job);
    if (job == NULL) {
        post_status("out of memory");
        return;
    }
    snprintf(job->prefix, sizeof job->prefix, "%s", prefix);
    job->first = first;
    job->second = second;
    job->bytes = bytes;
    pthread_t thread;
    if (pthread_create(&thread, NULL, worker, job) != 0) {
        free(job);
        post_status("cannot start the worker");
        return;
    }
    pthread_detach(thread);
}

/* ---------------------------------------------------------------- */
/* The one answer record, decoded by hand.                           */
/* ---------------------------------------------------------------- */

/* `file_dialog_result` (spec.rs kind 14): u64 dialog, u32 count, u32
 * reserved, then ONE counted value list holding three values per file —
 * I64 handle, Str name, Str local_path. The grouping IS the encoding;
 * cancel is count zero.
 *
 * There is no generated kaya_parse_file_dialog_result. The generator
 * emits a parse helper per click-shaped and per single-payload
 * occurrence (tools/kaya-bindgen/src/c.rs) and this record is neither,
 * so the floor reads the body — which is the floor being the floor,
 * exactly as it builds its widget tree out of kaya_tx_* calls.
 *
 * ONLY THE FIRST FILE IS KEPT. The open picker here is single-select
 * and a save dialog answers with exactly one locator or none (there is
 * no `multiple` twin of the picker's flag: no platform's save dialog
 * names two destinations), so one is all either request can produce. */
typedef struct {
    uint64_t dialog;
    uint32_t count;
    uint64_t handle;
    KayaVal name;
    KayaVal local_path;
} KayaFileResult;

static int parse_file_dialog_result(const uint8_t *rec, KayaFileResult *out) {
    const KayaRecordHeader *h = (const KayaRecordHeader *)rec;
    if (h->kind != KAYA_OCCURRENCE_FILE_DIALOG_RESULT)
        return 0;
    size_t at = sizeof(KayaRecordHeader);
    memcpy(&out->dialog, rec + at, 8);
    at += 8;
    memcpy(&out->count, rec + at, 4);
    at += 4;
    at += 4; /* reserved */
    /* The counted value sequence's head — {u32 count, u32 reserved} —
     * skipped rather than trusted: `count` above already says how many
     * files there are, and three values per file is the record's own
     * shape. */
    at += 8;
    out->handle = 0;
    out->name = kaya_str("");
    out->local_path = kaya_str("");
    if (out->count > 0) {
        KayaVal v;
        at = kaya_parse_value(rec, at, &v);
        out->handle = (uint64_t)v.i;
        at = kaya_parse_value(rec, at, &out->name);
        kaya_parse_value(rec, at, &out->local_path);
    }
    return 1;
}

/* ---------------------------------------------------------------- */

static void build_scene(void) {
    uint8_t buf[1024];
    KayaTx tx = {buf, 0};

    {
        /* set_window_prop, raw wire: u64 window, u32 wprop, u32 source,
         * value — the packer closes the record without one. */
        size_t start = kaya_wire_begin(&tx, KAYA_TX_SET_WINDOW_PROP);
        kaya_wire_u64(&tx, 0);
        kaya_wire_u32(&tx, KAYA_WPROP_TITLE);
        kaya_wire_u32(&tx, KAYA_SOURCE_CONST);
        kaya_wire_value(&tx, kaya_str("save"));
        kaya_wire_end(&tx, start);
    }

    kaya_tx_create_signal(&tx, SIG_STATUS, kaya_str("no file"));

    kaya_tx_create_widget(&tx, W_COLUMN, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, W_STATUS, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_STATUS, SIG_STATUS);
    /* Authored so the CLOSING read can address it: the AX read needs an
     * identifier, and an index read passes for an arm that ran and drew
     * nothing. */
    kaya_tx_set_a11y_id(&tx, W_STATUS, "status");
    kaya_tx_create_widget(&tx, W_OPEN, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_OPEN, "open");
    kaya_tx_create_widget(&tx, W_SAVE, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_SAVE, "save");
    kaya_tx_create_widget(&tx, W_SAVE_AS, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_SAVE_AS, "save as");
    kaya_tx_create_widget(&tx, W_REOPEN, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_REOPEN, "reopen");

    kaya_tx_add_child(&tx, W_COLUMN, W_STATUS);
    kaya_tx_add_child(&tx, W_COLUMN, W_OPEN);
    kaya_tx_add_child(&tx, W_COLUMN, W_SAVE);
    kaya_tx_add_child(&tx, W_COLUMN, W_SAVE_AS);
    kaya_tx_add_child(&tx, W_COLUMN, W_REOPEN);
    kaya_tx_mount(&tx, 0, W_COLUMN); /* window 0: the default */

    kaya_submit(tx.buf, tx.len);
}

static void *app(void *arg) {
    (void)arg;
    build_scene();

    /* The two capabilities the scene carries: the file the user OPENED,
     * and the destination the user later NAMED. Held as HANDLES, never
     * as paths — the phones have no re-openable path at all, and the
     * desktops must not be allowed to pass with one. Zero is "none":
     * the core mints handles from 1. */
    uint64_t source = 0, destination = 0;

    /* The dialog ids this guest chose, and the reason it has to keep
     * them: both requests answer with the SAME occurrence, so the id is
     * the only thing that says which question was asked. One id space,
     * one live dialog per process, and an id RETIRES when its result
     * fires — which is what makes the second save-as below legal after
     * the first was cancelled. */
    uint64_t next_dialog = 1, open_dialog = 0, save_dialog = 0;

    const uint8_t *rec;
    for (;;) {
        /* Posted work first, then the ring, then park. */
        drain_posted();
        size_t size = kaya_next_occurrence(&rec);
        if (size == KAYA_OCCURRENCE_SHUTDOWN)
            break;
        if (size == KAYA_OCCURRENCE_WOKEN)
            continue; /* nothing decoded; the drain above is the answer */

        uint64_t id;
        KayaVal keys[1];
        uint32_t n_keys;
        uint8_t buf[512];
        KayaFileResult result;

        if (kaya_parse_click(rec, &id, keys, 1, &n_keys)) {
            if (n_keys != 0)
                continue;
            KayaTx tx = {buf, 0};
            if (id == W_OPEN) {
                /* NO FILTER, deliberately: the names in this scene carry
                 * no extension, and a filter only decides a default view
                 * the guest still has to validate. */
                open_dialog = next_dialog++;
                kaya_tx_show_file_dialog(&tx, 0, open_dialog, 0, NULL, 0);
                kaya_submit(tx.buf, tx.len);
            } else if (id == W_SAVE) {
                /* SAVE-BACK NEEDS NO DIALOG. The user already chose this
                 * file, and the handle they chose it with is writable —
                 * the claim this step exists to drive, and which no
                 * scene, leg or test drove before this one. */
                work("saved", source, 0, "second draft");
            } else if (id == W_SAVE_AS) {
                /* THE SAVE REQUEST, SPELLED OUT: window 0, the id this
                 * guest minted, the name the dialog OPENS with, and an
                 * EMPTY filter list.
                 *
                 * THE EMPTY FILTERS ARE LOAD-BEARING. With allowed
                 * content types set, NSSavePanel appends the first
                 * allowed extension to an extension-less name — so the
                 * panel would answer "final.txt" for a scene that typed
                 * "final", and `expect_save_dialog` would read a name
                 * the guest never asked for. */
                save_dialog = next_dialog++;
                kaya_tx_show_save_dialog(&tx, 0, save_dialog, kaya_str("copy"),
                                         NULL, 0);
                kaya_submit(tx.buf, tx.len);
            } else if (id == W_REOPEN) {
                /* BOTH, in order: the file that was opened must still
                 * hold the save-back, and the destination must hold the
                 * save-as. A save-as that wrote through the ORIGINAL
                 * handle — the plausible bug, since this guest holds two
                 * handles that look alike — passes every earlier step
                 * and fails here. */
                work("reopened", source, destination, NULL);
            }
        } else if (parse_file_dialog_result(rec, &result)) {
            /* `local_path` is decoded and touched exactly once, here, to
             * say what it is for: a convenience for a desktop-only app,
             * empty on both phones, and never the thing this guest
             * reads. Everything below goes through the handle. */
            (void)result.local_path;
            if (result.dialog == open_dialog) {
                if (result.count == 0) {
                    /* The empty answer IS cancel, faithfully: no
                     * platform can confirm an empty selection. */
                    KayaTx tx = {buf, 0};
                    kaya_tx_write_signal(&tx, SIG_STATUS,
                                         kaya_str("open cancelled"));
                    kaya_submit(tx.buf, tx.len);
                    continue;
                }
                source = result.handle;
                work("opened", source, 0, NULL);
            } else if (result.dialog == save_dialog) {
                if (result.count == 0) {
                    /* CANCEL IS THE EMPTY ANSWER here too, and nothing
                     * is remembered for it: no destination, so the next
                     * save-as must ask again. The id has already retired
                     * in the core, which is the other half of what this
                     * step proves — a cancel that leaked the live slot
                     * would panic on the second show. */
                    KayaTx tx = {buf, 0};
                    kaya_tx_write_signal(&tx, SIG_STATUS,
                                         kaya_str("save cancelled"));
                    kaya_submit(tx.buf, tx.len);
                    continue;
                }
                /* THE NAME IS NOT ASSERTED, ANYWHERE. `result.name` is
                 * the name the dialog GOT, which is not the name this
                 * guest suggested — the user renamed it, and Android's
                 * SAF appends an extension matching the mime type at
                 * creation. The bytes are what the scene checks. */
                destination = result.handle;
                work("saved", destination, 0, "third draft");
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
    /* BEFORE ANYTHING IS SHOWN, so the picker the scene opens has
     * something to find. */
    make_scene_files();
    pthread_t app_thread;
    pthread_create(&app_thread, NULL, app, NULL);
    return kaya_run(); /* takes over the main thread until the app exits */
}
