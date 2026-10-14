/* The network images affordance scene (tools/scenes/netimage.steps;
 * docs/network-images-plan.md §5, N16's floor row) with every field
 * explicit: the phase as kaya_tx_set_phase's enum, the conditional write as
 * the collection_patch_if record, image_needed and image_released read off
 * the ring, and a worker of its own that PARKS until a click releases it,
 * posting back through a locked queue and kaya_wake() (guests/c/background.c
 * is the shape). No HTTP and no helper: the floor has neither. See
 * guests/rust/netimage.rs. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Guest-allocated ids; tools/check-c-ids.py holds the one id space. */
#define W_ROOT 1
#define W_CONTROLS 2
#define W_COVER 3
#define W_LIVE_ROW 4
#define W_RELEASE 5
#define W_REFRESH 6
#define W_JUNK 7
#define W_FAIL 8
#define W_ROWS_ROW 9
#define W_ROWS 10
#define W_DELETE 11
#define W_RETARGET 12
#define W_BAND 13
#define W_RELEASED 14
#define W_AGAIN 15
#define W_TRACKS 16
#define N_ROW 17
#define N_ART 18
#define N_TITLE 19
#define W_FAIL_ROW 20

#define SIG_ART 1
#define SIG_PHASE 2
#define SIG_BAND 3
#define SIG_RELEASED 4
#define SIG_AGAIN 5

#define C_TRACKS 1
#define F_TITLE 0
#define F_URL 1
#define F_ART 2
#define F_PHASE 3

#define ROWS 300

/* A "download" the worker holds. LIVE carries a cover, or none for a
 * failure; ROW a row's key, the URL it was for and its cover. */
enum { JOB_LIVE, JOB_ROW };
#define NO_COVER (-1)
typedef struct {
    int kind;
    int cover;
    char key[8];
    char url[16];
} Job;

static const char *const COVER_NAMES[3] = {
    "covers/cover-600.jpg", "covers/cover-320.jpg", "covers/cover-1000.jpg"};
static uint8_t *covers[3];
static size_t cover_lens[3];

/* App thread -> worker: whole batches, as a click releases them. */
#define MAX_JOBS (ROWS + 8)
static pthread_mutex_t jobs_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t jobs_cond = PTHREAD_COND_INITIALIZER;
static Job jobs[MAX_JOBS];
static unsigned jobs_count = 0;

/* Worker -> app thread: one job a transaction, drained at the loop's top. */
static pthread_mutex_t post_lock = PTHREAD_MUTEX_INITIALIZER;
static Job posted[MAX_JOBS];
static unsigned posted_count = 0;

/* App thread only. */
static int live_cover = 0; /* the job the next release sends */
static int live_armed = 1;
static Job pending[MAX_JOBS];
static unsigned pending_count = 0;
static unsigned char needed[ROWS];
static unsigned char ever[ROWS];
static unsigned ever_count = 0;
static char twice[8] = "";

static void submit(KayaTx *tx) {
    if (!kaya_tx_ok(tx)) {
        fprintf(stderr, "kaya: the netimage guest's transaction needs %zu bytes and was given %zu\n",
                tx->len, tx->cap);
        _exit(1);
    }
    kaya_submit(tx->buf, tx->len);
}

/* Packed by hand: the generated setter closes the record BEFORE the value. */
static void window_prop(KayaTx *tx, uint32_t prop, KayaVal value) {
    size_t start = kaya_wire_begin(tx, KAYA_TX_SET_WINDOW_PROP);
    kaya_wire_u64(tx, 0);
    kaya_wire_u32(tx, prop);
    kaya_wire_u32(tx, KAYA_SOURCE_CONST);
    kaya_wire_value(tx, value);
    kaya_wire_end(tx, start);
}

/* A blob handle lives for ONE submit, so every transaction registers its
 * own, on the app thread that submits it. */
static KayaVal cover_blob(int cover) {
    return kaya_blob(kaya_blob_register(covers[cover], cover_lens[cover]));
}

static KayaVal empty_blob(void) {
    return kaya_blob(kaya_blob_register(NULL, 0));
}

static void load_covers(void) {
    for (int i = 0; i < 3; i++) {
        uint64_t asset = kaya_asset_open((const uint8_t *)COVER_NAMES[i], strlen(COVER_NAMES[i]));
        uintptr_t len = 0;
        const uint8_t *bytes = asset == 0 ? NULL : kaya_asset_bytes(asset, &len);
        if (bytes == NULL) {
            fprintf(stderr, "kaya: the asset %s did not open\n", COVER_NAMES[i]);
            _exit(1);
        }
        covers[i] = malloc(len);
        memcpy(covers[i], bytes, len);
        cover_lens[i] = len;
        kaya_asset_release(asset);
    }
}

static void send_jobs(const Job *batch, unsigned n) {
    pthread_mutex_lock(&jobs_lock);
    for (unsigned i = 0; i < n && jobs_count < MAX_JOBS; i++)
        jobs[jobs_count++] = batch[i];
    pthread_cond_broadcast(&jobs_cond);
    pthread_mutex_unlock(&jobs_lock);
}

/* The WORKER: parks until a batch arrives, then posts each job back. */
static void *worker(void *arg) {
    (void)arg;
    for (;;) {
        Job batch[MAX_JOBS];
        unsigned n;
        pthread_mutex_lock(&jobs_lock);
        while (jobs_count == 0)
            pthread_cond_wait(&jobs_cond, &jobs_lock);
        n = jobs_count;
        memcpy(batch, jobs, n * sizeof(Job));
        jobs_count = 0;
        pthread_mutex_unlock(&jobs_lock);
        for (unsigned i = 0; i < n; i++) {
            pthread_mutex_lock(&post_lock);
            if (posted_count < MAX_JOBS)
                posted[posted_count++] = batch[i];
            pthread_mutex_unlock(&post_lock);
            /* Posted work never enters the ring: a wake is the only notification. */
            kaya_wake();
        }
    }
    return NULL;
}

/* Each posted job is its own transaction; a row's result is ONE
 * collection_patch_if guarded on the row's URL, so a row deleted or moved
 * on meanwhile drops it (N7). */
static void drain_posted(void) {
    Job batch[MAX_JOBS];
    unsigned n;
    pthread_mutex_lock(&post_lock);
    n = posted_count;
    memcpy(batch, posted, n * sizeof(Job));
    posted_count = 0;
    pthread_mutex_unlock(&post_lock);
    for (unsigned i = 0; i < n; i++) {
        uint8_t buf[512];
        KayaTx tx = {buf, 0, sizeof buf};
        const Job *job = &batch[i];
        if (job->kind == JOB_ROW) {
            KayaVal fields[] = {kaya_i64(F_ART), kaya_i64(F_PHASE)};
            KayaVal values[] = {cover_blob(job->cover), kaya_i64(KAYA_IMAGE_PHASE_SHOWN)};
            kaya_tx_collection_patch_if(&tx, C_TRACKS, NULL, 0, kaya_str(job->key), F_URL, 0,
                                        kaya_str(job->url), fields, 2, values, 2);
        } else if (job->cover == NO_COVER) {
            kaya_tx_write_signal(&tx, SIG_PHASE, kaya_i64(KAYA_IMAGE_PHASE_FAILED));
        } else {
            kaya_tx_write_signal(&tx, SIG_ART, cover_blob(job->cover));
            kaya_tx_write_signal(&tx, SIG_PHASE, kaya_i64(KAYA_IMAGE_PHASE_SHOWN));
        }
        submit(&tx);
    }
}

/* The create calls stay at the call site, where check-c-ids reads them. */
static void button(KayaTx *tx, uint64_t row, uint64_t id, const char *name) {
    kaya_tx_set_text(tx, id, name);
    kaya_tx_set_a11y_id(tx, id, name);
    kaya_tx_add_child(tx, row, id);
}

static void label(KayaTx *tx, uint64_t id, uint64_t signal, const char *a11y_id) {
    kaya_tx_bind_text(tx, id, signal);
    kaya_tx_set_a11y_id(tx, id, a11y_id);
    kaya_tx_add_child(tx, W_CONTROLS, id);
}

static void build_scene(void) {
    uint8_t buf[4096];
    KayaTx tx = {buf, 0, sizeof buf};

    window_prop(&tx, KAYA_WPROP_TITLE, kaya_str("netimage"));
    window_prop(&tx, KAYA_WPROP_WIDTH, kaya_f64(820.0));
    window_prop(&tx, KAYA_WPROP_HEIGHT, kaya_f64(640.0));

    kaya_tx_create_signal(&tx, SIG_ART, empty_blob());
    kaya_tx_create_signal(&tx, SIG_PHASE, kaya_i64(KAYA_IMAGE_PHASE_LOADING));
    kaya_tx_create_signal(&tx, SIG_BAND, kaya_str("band: -"));
    kaya_tx_create_signal(&tx, SIG_RELEASED, kaya_str("released: none"));
    kaya_tx_create_signal(&tx, SIG_AGAIN, kaya_str("again: none"));

    kaya_tx_create_widget(&tx, W_ROOT, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, W_CONTROLS, KAYA_KIND_COLUMN);
    kaya_tx_add_child(&tx, W_ROOT, W_CONTROLS);

    /* A busy image declares its box: fit and both bounds (N3). */
    kaya_tx_create_widget(&tx, W_COVER, KAYA_KIND_IMAGE);
    kaya_tx_bind_source(&tx, W_COVER, SIG_ART);
    kaya_tx_set_max_width(&tx, W_COVER, 96.0);
    kaya_tx_set_max_height(&tx, W_COVER, 96.0);
    kaya_tx_set_fit(&tx, W_COVER, KAYA_FIT_COVER);
    kaya_tx_bind_phase(&tx, W_COVER, SIG_PHASE);
    kaya_tx_set_a11y_id(&tx, W_COVER, "cover");
    kaya_tx_set_a11y_label(&tx, W_COVER, "Cover");
    kaya_tx_add_child(&tx, W_CONTROLS, W_COVER);

    kaya_tx_create_widget(&tx, W_LIVE_ROW, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, W_RELEASE, KAYA_KIND_BUTTON);
    button(&tx, W_LIVE_ROW, W_RELEASE, "release");
    kaya_tx_create_widget(&tx, W_REFRESH, KAYA_KIND_BUTTON);
    button(&tx, W_LIVE_ROW, W_REFRESH, "refresh");
    kaya_tx_add_child(&tx, W_CONTROLS, W_LIVE_ROW);
    kaya_tx_create_widget(&tx, W_FAIL_ROW, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, W_JUNK, KAYA_KIND_BUTTON);
    button(&tx, W_FAIL_ROW, W_JUNK, "junk");
    kaya_tx_create_widget(&tx, W_FAIL, KAYA_KIND_BUTTON);
    button(&tx, W_FAIL_ROW, W_FAIL, "fail");
    kaya_tx_add_child(&tx, W_CONTROLS, W_FAIL_ROW);
    kaya_tx_create_widget(&tx, W_ROWS_ROW, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, W_ROWS, KAYA_KIND_BUTTON);
    button(&tx, W_ROWS_ROW, W_ROWS, "rows");
    kaya_tx_create_widget(&tx, W_DELETE, KAYA_KIND_BUTTON);
    button(&tx, W_ROWS_ROW, W_DELETE, "delete");
    kaya_tx_create_widget(&tx, W_RETARGET, KAYA_KIND_BUTTON);
    button(&tx, W_ROWS_ROW, W_RETARGET, "retarget");
    kaya_tx_add_child(&tx, W_CONTROLS, W_ROWS_ROW);
    kaya_tx_create_widget(&tx, W_BAND, KAYA_KIND_LABEL);
    label(&tx, W_BAND, SIG_BAND, "band");
    kaya_tx_create_widget(&tx, W_RELEASED, KAYA_KIND_LABEL);
    label(&tx, W_RELEASED, SIG_RELEASED, "released");
    kaya_tx_create_widget(&tx, W_AGAIN, KAYA_KIND_LABEL);
    label(&tx, W_AGAIN, SIG_AGAIN, "again");

    /* A row: title, the URL its art comes from, the art's bytes, its phase. */
    kaya_tx_create_collection(&tx, C_TRACKS,
                              (KayaVariantSchema[]){{(uint32_t[]){KAYA_VALUE_STR, KAYA_VALUE_STR,
                                                                  KAYA_VALUE_BLOB, KAYA_VALUE_I64},
                                                     4}},
                              1);
    kaya_tx_create_for(&tx, W_TRACKS, C_TRACKS);
    kaya_tx_create_widget(&tx, N_ROW, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, N_ART, KAYA_KIND_IMAGE);
    /* `level` 0: the element of the For this node sits directly inside. */
    kaya_tx_bind_source_element(&tx, N_ART, 0, F_ART);
    kaya_tx_set_max_width(&tx, N_ART, 20.0);
    kaya_tx_set_max_height(&tx, N_ART, 20.0);
    kaya_tx_set_fit(&tx, N_ART, KAYA_FIT_COVER);
    kaya_tx_bind_phase_element(&tx, N_ART, 0, F_PHASE);
    kaya_tx_set_a11y_id(&tx, N_ART, "art");
    kaya_tx_create_widget(&tx, N_TITLE, KAYA_KIND_LABEL);
    kaya_tx_bind_text_element(&tx, N_TITLE, 0, F_TITLE);
    kaya_tx_add_child(&tx, N_ROW, N_ART);
    kaya_tx_add_child(&tx, N_ROW, N_TITLE);
    kaya_tx_template_end(&tx);
    KayaVal titles[] = {kaya_str("Art"), kaya_str("Title")};
    kaya_tx_set_column_headers(&tx, W_TRACKS, 0xFFFFFFFFu, 0, 2, 0, titles, 2);
    kaya_tx_set_a11y_id(&tx, W_TRACKS, "tracks");
    kaya_tx_set_grow(&tx, W_TRACKS, 1.0);
    kaya_tx_add_child(&tx, W_ROOT, W_TRACKS);
    kaya_tx_mount(&tx, 0, W_ROOT); /* window 0: the default */
    submit(&tx);

    /* The rows in their own transaction: 300 records want 64 KB. */
    static uint8_t rows_buf[65536];
    KayaTx rows = {rows_buf, 0, sizeof rows_buf};
    KayaVal none = empty_blob();
    for (int i = 0; i < ROWS; i++) {
        char key[8], title[16], url[16];
        snprintf(key, sizeof key, "t%03d", i);
        snprintf(title, sizeof title, "Track %d", i);
        snprintf(url, sizeof url, "u/%d", i);
        KayaVal fields[] = {kaya_str(title), kaya_str(url), none,
                            kaya_i64(KAYA_IMAGE_PHASE_LOADING)};
        kaya_tx_collection_insert(&rows, C_TRACKS, NULL, 0, kaya_str(key), 0, fields, 4);
    }
    submit(&rows);
}

static int row_index(const KayaVal *key) {
    if (key->type != KAYA_VALUE_STR || key->s_len < 2 || key->s_len > 6 || key->s[0] != 't')
        return -1;
    int i = 0;
    for (uint32_t c = 1; c < key->s_len; c++)
        i = i * 10 + (key->s[c] - '0');
    return i < ROWS ? i : -1;
}

static void on_needed(int i) {
    if (needed[i] && twice[0] == '\0')
        snprintf(twice, sizeof twice, "t%03d", i);
    needed[i] = 1;
    if (!ever[i]) {
        ever[i] = 1;
        ever_count++;
    }
    if (pending_count < MAX_JOBS) {
        Job *job = &pending[pending_count++];
        job->kind = JOB_ROW;
        job->cover = i % 3;
        snprintf(job->key, sizeof job->key, "t%03d", i);
        snprintf(job->url, sizeof job->url, "u/%d", i);
    }
    char band[32], again[32];
    if (ever_count < ROWS)
        snprintf(band, sizeof band, "band: partial");
    else
        snprintf(band, sizeof band, "band: %u", ever_count);
    snprintf(again, sizeof again, "again: %s", twice[0] ? twice : "none");
    uint8_t buf[256];
    KayaTx tx = {buf, 0, sizeof buf};
    kaya_tx_write_signal(&tx, SIG_BAND, kaya_str(band));
    kaya_tx_write_signal(&tx, SIG_AGAIN, kaya_str(again));
    submit(&tx);
}

static void on_released(int i) {
    char key[8];
    snprintf(key, sizeof key, "t%03d", i);
    needed[i] = 0;
    unsigned kept = 0;
    for (unsigned j = 0; j < pending_count; j++)
        if (strcmp(pending[j].key, key) != 0)
            pending[kept++] = pending[j];
    pending_count = kept;
    uint8_t buf[256];
    KayaTx tx = {buf, 0, sizeof buf};
    kaya_tx_write_signal(&tx, SIG_RELEASED, kaya_str("released: some"));
    submit(&tx);
}

static void on_click(uint64_t id) {
    uint8_t buf[512];
    KayaTx tx = {buf, 0, sizeof buf};
    if (id == W_RELEASE) {
        if (live_armed) {
            Job job = {JOB_LIVE, live_cover, "", ""};
            send_jobs(&job, 1);
            live_armed = 0;
        }
        return;
    }
    if (id == W_REFRESH) {
        live_cover = 1;
        live_armed = 1;
        kaya_tx_write_signal(&tx, SIG_PHASE, kaya_i64(KAYA_IMAGE_PHASE_LOADING));
    } else if (id == W_JUNK) {
        static const char junk[] = "not an image";
        kaya_tx_write_signal(&tx, SIG_ART,
                             kaya_blob(kaya_blob_register((const uint8_t *)junk, strlen(junk))));
        kaya_tx_write_signal(&tx, SIG_PHASE, kaya_i64(KAYA_IMAGE_PHASE_SHOWN));
    } else if (id == W_FAIL) {
        live_cover = NO_COVER;
        live_armed = 1;
        kaya_tx_write_signal(&tx, SIG_ART, empty_blob());
        kaya_tx_write_signal(&tx, SIG_PHASE, kaya_i64(KAYA_IMAGE_PHASE_LOADING));
    } else if (id == W_ROWS) {
        memset(needed, 0, sizeof needed);
        send_jobs(pending, pending_count);
        pending_count = 0;
        return;
    } else if (id == W_DELETE) {
        kaya_tx_collection_remove(&tx, C_TRACKS, NULL, 0, kaya_str("t299"));
    } else if (id == W_RETARGET) {
        if (pending_count < MAX_JOBS) {
            memmove(&pending[1], &pending[0], pending_count * sizeof(Job));
            pending_count++;
        }
        Job job = {JOB_ROW, 2, "t298", "u/298b"};
        pending[0] = job;
        kaya_tx_collection_update_field(&tx, C_TRACKS, NULL, 0, kaya_str("t298"), F_URL, 0,
                                        kaya_str("u/298b"));
    } else {
        return;
    }
    submit(&tx);
}

static void *app(void *arg) {
    (void)arg;
    load_covers();
    build_scene();
    pthread_t worker_thread;
    pthread_create(&worker_thread, NULL, worker, NULL);
    const uint8_t *rec;
    for (;;) {
        /* Draining at the TOP is what makes a wake sufficient. */
        drain_posted();
        size_t size = kaya_next_occurrence(&rec);
        if (size == KAYA_OCCURRENCE_SHUTDOWN)
            break;
        if (size == KAYA_OCCURRENCE_WOKEN)
            continue;
        uint64_t id;
        KayaVal keys[2];
        uint32_t n_keys;
        if (kaya_parse_click(rec, &id, keys, 2, &n_keys)) {
            if (n_keys == 0)
                on_click(id);
        } else if (kaya_parse_image_needed(rec, &id, keys, 2, &n_keys)) {
            int i = n_keys == 1 && id == N_ART ? row_index(&keys[0]) : -1;
            if (i >= 0)
                on_needed(i);
        } else if (kaya_parse_image_released(rec, &id, keys, 2, &n_keys)) {
            int i = n_keys == 1 && id == N_ART ? row_index(&keys[0]) : -1;
            if (i >= 0)
                on_released(i);
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
