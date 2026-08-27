/* The save scene from C, at the explicit wire floor: the save request
 * is kaya_tx_show_save_dialog, and BOTH dialogs answer with the one
 * occurrence the guest tells apart by the dialog id it chose itself
 * (docs/save-plan.md D1-D5). Semantics: guests/rust/save.rs. Contract:
 * tools/scenes/save.steps.
 *
 * NO NAME IN THIS SCENE CARRIES AN EXTENSION: a save panel may publish
 * its name field with the extension hidden, so `expect_save_dialog`
 * would read the stem on one machine and the whole name on another
 * (docs/deferred.md).
 *
 * THE WORK RUNS OFF THE APP THREAD, because `kaya_open_picked` blocks
 * and a cloud provider may download the whole file first. */

#include <kaya.h>
#include <kaya_wire.h>

#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* Guest-allocated ids, counted from 1 per space. CREATION ORDER IS
 * CONTRACT: the harness addresses by creation order within a kind and
 * the script names label#0 and button#0..3 = open, save, save as,
 * reopen. Swapping two buttons presses the wrong one rather than
 * failing. */
#define SIG_STATUS 1

#define W_COLUMN 1
#define W_STATUS 2  /* label#0 */
#define W_OPEN 3    /* button#0 */
#define W_SAVE 4    /* button#1 */
#define W_SAVE_AS 5 /* button#2 */
#define W_REOPEN 6  /* button#3 */

/* The guest writes the files and the interpreter aims the panel at
 * `$TMP/kaya-save-$PID`, so both halves must compute the same directory
 * with no runner involvement: `TMPDIR` or "/tmp", never Darwin's
 * per-user directory (docs/traps.md). The pid keeps parallel legs from
 * colliding; the script names only BASENAMES. */
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
    /* Trailing separators trimmed, as the harness's expander trims them:
     * "…//kaya-save-N" is fine to POSIX and not to a reader that parses
     * the name. */
    size_t len = strlen(tmp);
    while (len > 1 && tmp[len - 1] == '/')
        len--;
    snprintf(scene_dir, sizeof scene_dir, "%.*s/kaya-save-%ld", (int)len, tmp,
             (long)getpid());
    if (mkdir(scene_dir, 0700) != 0 && errno != EEXIST) {
        fprintf(stderr, "save: cannot make %s: %s\n", scene_dir, strerror(errno));
        exit(1);
    }
    /* The file the scene opens, plus the DECOY the picker needs: with one
     * file in the directory a dialog completes with it even when nothing
     * was selected. "decoy" sorts FIRST, so a backend that selects
     * nothing fails the byte assertion. */
    write_scene_file("draft", "first draft");
    write_scene_file("decoy", "decoy");
}

/* `kaya_open_picked` is one of the two entries in the whole C API that
 * is SAFE FROM ANY THREAD (kaya_wake is the other), which is what lets
 * the worker below call it. It answers 0 or a POSITIVE errno. */
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

/* FILE_MODE_WRITE truncates, on a picked file and on a save destination
 * alike; the destination only adds the create, which is the CORE's
 * (there is no FILE_MODE_CREATE to ask for — docs/save-plan.md D1). */
static void write_back(uint64_t handle, const char *bytes, char *out, size_t cap) {
    int64_t raw;
    uint32_t seekable;
    int rc = kaya_open_picked(handle, FILE_MODE_WRITE, &raw, &seekable);
    if (rc != 0) {
        /* Without the create this is where a save destination answers
         * ENOENT, for a file the user just named. */
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

/* The post queue, one status write wide (guests/c/background.c has the
 * long version). */
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
    /* Posted work is not an occurrence and never enters the ring, so a
     * wake is the only way the parked app thread hears about it. */
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
    KayaTx tx = {buf, 0, sizeof buf};
    for (unsigned i = 0; i < n; i++)
        kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str(batch[i]));
    kaya_submit(tx.buf, tx.len);
}

/* One file operation as DATA rather than a closure — closures do not
 * cross the C ABI. */
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

/* Detached, because nothing joins it: the answer comes back through the
 * queue above, and kaya supplies no waiting primitive. */
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

/* `file_dialog_result` (spec.rs kind 14): u64 dialog, u32 count, u32
 * reserved, then ONE counted value list holding three values per file —
 * I64 handle, Str name, Str local_path. Cancel is count zero. The
 * generator emits no parser for this record, so the floor reads the
 * body. Only the first file is kept. */
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
    /* Skips the value list's own head, {u32 count, u32 reserved}. */
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

static void build_scene(void) {
    uint8_t buf[1024];
    KayaTx tx = {buf, 0, sizeof buf};

    {
        /* Packed by hand: the generated kaya_tx_set_window_prop closes
         * the record BEFORE the value. */
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
    /* Authored so the closing AX read can address it by identifier. */
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

    /* The file the user OPENED and the destination the user later NAMED,
     * held as HANDLES and never as paths — the phones have no
     * re-openable path. Zero is "none": the core mints handles from 1. */
    uint64_t source = 0, destination = 0;

    /* Both requests answer with the SAME occurrence, so the id is the
     * only thing saying which question was asked. One live dialog per
     * process; an id RETIRES when its result fires. */
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
            KayaTx tx = {buf, 0, sizeof buf};
            if (id == W_OPEN) {
                /* No filter: the names here carry no extension. */
                open_dialog = next_dialog++;
                kaya_tx_show_file_dialog(&tx, 0, open_dialog, 0, NULL, 0);
                kaya_submit(tx.buf, tx.len);
            } else if (id == W_SAVE) {
                /* Save-back needs no dialog: the handle the user chose
                 * the file with is writable. */
                work("saved", source, 0, "second draft");
            } else if (id == W_SAVE_AS) {
                /* THE EMPTY FILTER LIST MATTERS: with allowed content
                 * types set, NSSavePanel appends the first allowed
                 * extension to an extension-less name, and the panel
                 * would answer a name this guest never asked for
                 * (docs/deferred.md). */
                save_dialog = next_dialog++;
                kaya_tx_show_save_dialog(&tx, 0, save_dialog, kaya_str("copy"),
                                         NULL, 0);
                kaya_submit(tx.buf, tx.len);
            } else if (id == W_REOPEN) {
                /* Both, in order: a save-as that wrote through the
                 * ORIGINAL handle passes every earlier step and fails
                 * here. */
                work("reopened", source, destination, NULL);
            }
        } else if (parse_file_dialog_result(rec, &result)) {
            /* `local_path` is touched exactly once, here: it is EMPTY ON
             * BOTH PHONES, so everything below goes through the handle. */
            (void)result.local_path;
            if (result.dialog == open_dialog) {
                if (result.count == 0) {
                    /* The empty answer IS cancel: no platform can
                     * confirm an empty selection. */
                    KayaTx tx = {buf, 0, sizeof buf};
                    kaya_tx_write_signal(&tx, SIG_STATUS,
                                         kaya_str("open cancelled"));
                    kaya_submit(tx.buf, tx.len);
                    continue;
                }
                source = result.handle;
                work("opened", source, 0, NULL);
            } else if (result.dialog == save_dialog) {
                if (result.count == 0) {
                    /* Nothing is remembered for a cancel: no
                     * destination, so the next save-as asks again. */
                    KayaTx tx = {buf, 0, sizeof buf};
                    kaya_tx_write_signal(&tx, SIG_STATUS,
                                         kaya_str("save cancelled"));
                    kaya_submit(tx.buf, tx.len);
                    continue;
                }
                /* `result.name` is asserted NOWHERE: it is the name the
                 * dialog got, not the one this guest suggested (Android's
                 * SAF appends an extension at creation). */
                destination = result.handle;
                work("saved", destination, 0, "third draft");
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
    /* BEFORE ANYTHING IS SHOWN, so the picker has something to find. */
    make_scene_files();
    pthread_t app_thread;
    pthread_create(&app_thread, NULL, app, NULL);
    return kaya_run(); /* takes over the main thread until the app exits */
}
