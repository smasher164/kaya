/* The background scene (tools/scenes/background.steps): work off the app
 * thread, posted back. Every other C guest that posts points here. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* Guest-allocated ids; tools/check-c-ids.py holds the one id space. */
#define SIG_STATUS 1
#define SIG_ALIVE 2
#define SIG_NESTED 3
#define W_COLUMN 1
#define W_STATUS 2
#define W_ALIVE 3
#define W_NESTED 4
#define W_START 5
#define W_PING 6
#define W_RELEASE 7
#define W_NEST 8

/* The release must NEVER BLOCK the app thread. */
static pthread_mutex_t release_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t release_cond = PTHREAD_COND_INITIALIZER;
static int released = 0;

/* Closures do not cross the C ABI, so each entry spells its destination. */
#define MAX_POSTED 16
typedef struct {
    uint64_t signal;
    char *acc;
    size_t acc_cap;
    char step[8];
} PostedWrite;
static pthread_mutex_t post_lock = PTHREAD_MUTEX_INITIALIZER;
static PostedWrite posted_steps[MAX_POSTED];
static unsigned posted_count = 0;

/* App thread only, inside a drained post, so no lock. */
static char landed[32] = "";
static char nested[8] = "";

/* Called from the WORKER thread. */
static void post_step(uint64_t signal, char *acc, size_t acc_cap, const char *step) {
    pthread_mutex_lock(&post_lock);
    if (posted_count < MAX_POSTED) {
        PostedWrite *w = &posted_steps[posted_count++];
        w->signal = signal;
        w->acc = acc;
        w->acc_cap = acc_cap;
        snprintf(w->step, sizeof w->step, "%s", step);
    }
    pthread_mutex_unlock(&post_lock);
    /* Posted work never enters the ring: a wake is the only notification. */
    kaya_wake();
}

/* The lock is dropped BEFORE the batch is applied: a post made while
 * draining lands in the next one. */
static void drain_posted(void) {
    PostedWrite batch[MAX_POSTED];
    unsigned n;
    pthread_mutex_lock(&post_lock);
    n = posted_count;
    memcpy(batch, posted_steps, sizeof batch);
    posted_count = 0;
    pthread_mutex_unlock(&post_lock);
    if (n == 0)
        return;
    uint8_t buf[512];
    KayaTx tx = {buf, 0, sizeof buf};
    for (unsigned i = 0; i < n; i++) {
        strncat(batch[i].acc, batch[i].step, batch[i].acc_cap - strlen(batch[i].acc) - 1);
        kaya_tx_write_signal(&tx, batch[i].signal, kaya_str(batch[i].acc));
    }
    kaya_submit(tx.buf, tx.len);
}

static void *worker(void *arg) {
    (void)arg;
    pthread_mutex_lock(&release_lock);
    while (!released)
        pthread_cond_wait(&release_cond, &release_lock);
    pthread_mutex_unlock(&release_lock);
    post_step(SIG_STATUS, landed, sizeof landed, "1");
    post_step(SIG_STATUS, landed, sizeof landed, "2");
    post_step(SIG_STATUS, landed, sizeof landed, "3");
    return NULL;
}

static void build_scene(void) {
    uint8_t buf[1024];
    KayaTx tx = {buf, 0, sizeof buf};

    kaya_tx_create_signal(&tx, SIG_STATUS, kaya_str("idle"));
    kaya_tx_create_signal(&tx, SIG_ALIVE, kaya_str("-"));
    kaya_tx_create_signal(&tx, SIG_NESTED, kaya_str("-"));

    kaya_tx_create_widget(&tx, W_COLUMN, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, W_STATUS, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_STATUS, SIG_STATUS);
    kaya_tx_set_a11y_id(&tx, W_STATUS, "status");
    kaya_tx_create_widget(&tx, W_ALIVE, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_ALIVE, SIG_ALIVE);
    kaya_tx_set_a11y_id(&tx, W_ALIVE, "alive");
    kaya_tx_create_widget(&tx, W_NESTED, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_NESTED, SIG_NESTED);
    kaya_tx_set_a11y_id(&tx, W_NESTED, "nested");

    kaya_tx_create_widget(&tx, W_START, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_START, "start");
    kaya_tx_create_widget(&tx, W_PING, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_PING, "ping");
    kaya_tx_create_widget(&tx, W_RELEASE, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_RELEASE, "release");
    kaya_tx_create_widget(&tx, W_NEST, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_NEST, "nest");

    kaya_tx_add_child(&tx, W_COLUMN, W_STATUS);  /* label#0 */
    kaya_tx_add_child(&tx, W_COLUMN, W_ALIVE);   /* label#1 */
    kaya_tx_add_child(&tx, W_COLUMN, W_NESTED);  /* label#2 */
    kaya_tx_add_child(&tx, W_COLUMN, W_START);   /* button#0 */
    kaya_tx_add_child(&tx, W_COLUMN, W_PING);    /* button#1 */
    kaya_tx_add_child(&tx, W_COLUMN, W_RELEASE); /* button#2 */
    kaya_tx_add_child(&tx, W_COLUMN, W_NEST);    /* button#3 */
    kaya_tx_mount(&tx, 0, W_COLUMN);             /* window 0: the default */

    kaya_submit(tx.buf, tx.len);
}

static void *app(void *arg) {
    (void)arg;
    build_scene();
    pthread_t worker_thread;
    int started = 0;
    const uint8_t *rec;
    for (;;) {
            /* Draining at the TOP is what makes a wake sufficient. */
        drain_posted();
        size_t size = kaya_next_occurrence(&rec);
        if (size == KAYA_OCCURRENCE_SHUTDOWN)
            break;
        if (size == KAYA_OCCURRENCE_WOKEN)
            continue; /* nothing decoded; the drain above is the answer */

        uint64_t id;
        KayaVal keys[2];
        uint32_t n_keys;
        if (!kaya_parse_click(rec, &id, keys, 2, &n_keys) || n_keys != 0)
            continue;

        uint8_t buf[512];
        KayaTx tx = {buf, 0, sizeof buf};
        if (id == W_START) {
            if (!started) {
                pthread_create(&worker_thread, NULL, worker, NULL);
                started = 1;
            }
            kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str("working"));
            kaya_submit(tx.buf, tx.len);
        } else if (id == W_PING) {
            kaya_tx_write_signal(&tx, SIG_ALIVE, kaya_str("alive"));
            kaya_submit(tx.buf, tx.len);
        } else if (id == W_RELEASE) {
            pthread_mutex_lock(&release_lock);
            released = 1;
            pthread_cond_broadcast(&release_cond);
            pthread_mutex_unlock(&release_lock);
        } else if (id == W_NEST) {
            /* A post from INSIDE a handler QUEUES for after; it never nests. */
            strncat(nested, "a", sizeof nested - strlen(nested) - 1);
            post_step(SIG_NESTED, nested, sizeof nested, "b");
            strncat(nested, "c", sizeof nested - strlen(nested) - 1);
            kaya_tx_write_signal(&tx, SIG_NESTED, kaya_str(nested));
            kaya_submit(tx.buf, tx.len);
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
