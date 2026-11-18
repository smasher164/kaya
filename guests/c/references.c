/* The references scene (tools/scenes/references.steps;
 * docs/restoration-plan.md SR11, SR12) on the C floor: a picked file's
 * durable reference rides the session store across a relaunch and redeems
 * for its bytes; a foreign token and a deleted file are refused by name. */

#include <kaya.h>
#include <kaya_wire.h>

#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define W_ROOT 1
#define W_STATUS 2
#define W_PICK 3
#define W_FOREIGN 4
#define W_DELETE 5
#define SIG_STATUS 1
#define DIALOG 1

#define SCOPE_APP 0

static const char *const REFUSALS[] = {"", "missing", "revoked", "provider_gone", "foreign", "cap"};

static char saved[8192];

static void status(const char *text) {
    uint8_t buf[512];
    KayaTx tx = {buf, 0, sizeof buf};
    kaya_tx_write_signal(&tx, SIG_STATUS, kaya_str(text));
    kaya_submit(tx.buf, tx.len);
}

static void write_scene_file(const char *dir, const char *name, const char *body) {
    char path[1024];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "w");
    if (f) {
        fputs(body, f);
        fclose(f);
    }
}

/* The bytes a token redeems for, or the refusal's branch; the sentence goes
 * to stderr, where the leg log keeps it. `path`, when given, receives the
 * redeemed file's local path. */
static void read_back(const char *token, char *out, size_t cap, char *path, size_t path_cap) {
    uint64_t handle = 0;
    char text[8192];
    size_t len = 0;
    uint32_t code = kaya_reference_redeem((const uint8_t *)token, strlen(token), &handle, (uint8_t *)text,
                                          sizeof text - 1, &len);
    text[len < sizeof text ? len : sizeof text - 1] = 0;
    if (code != 0) {
        fprintf(stderr, "references: %s\n", text);
        snprintf(out, cap, "%s", code < 6 ? REFUSALS[code] : "refused");
        return;
    }
    if (path) {
        size_t plen = 0;
        kaya_picked_text(handle, 1, (uint8_t *)path, path_cap - 1, &plen);
        path[plen < path_cap ? plen : path_cap - 1] = 0;
        return;
    }
    int64_t raw;
    uint32_t seekable;
    int rc = kaya_open_picked(handle, KAYA_FILE_MODE_READ, &raw, &seekable);
    if (rc != 0) {
        snprintf(out, cap, "open failed: %s", strerror(rc));
        return;
    }
    char bytes[256];
    ssize_t n = read((int)raw, bytes, sizeof bytes - 1);
    close((int)raw);
    bytes[n > 0 ? n : 0] = 0;
    snprintf(out, cap, "redeemed: %s", bytes);
}

static void build_scene(void) {
    uint8_t buf[2048];
    KayaTx tx = {buf, 0, sizeof buf};
    {
        size_t start = kaya_wire_begin(&tx, KAYA_TX_SET_WINDOW_PROP);
        kaya_wire_u64(&tx, 0);
        kaya_wire_u32(&tx, KAYA_WPROP_TITLE);
        kaya_wire_u32(&tx, KAYA_SOURCE_CONST);
        kaya_wire_value(&tx, kaya_str("references"));
        kaya_wire_end(&tx, start);
    }
    kaya_tx_create_signal(&tx, SIG_STATUS, kaya_str(saved[0] ? "redeeming" : "no reference"));
    kaya_tx_create_widget(&tx, W_ROOT, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, W_STATUS, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_STATUS, SIG_STATUS);
    kaya_tx_set_a11y_id(&tx, W_STATUS, "status");
    static const char *const BUTTONS[] = {"pick", "foreign", "delete"};
    for (uint64_t i = 0; i < 3; i++) {
        kaya_tx_create_widget(&tx, W_PICK + i, KAYA_KIND_BUTTON);
        kaya_tx_set_text(&tx, W_PICK + i, BUTTONS[i]);
        kaya_tx_set_a11y_id(&tx, W_PICK + i, BUTTONS[i]);
    }
    kaya_tx_add_child(&tx, W_ROOT, W_STATUS);
    for (uint64_t i = 0; i < 3; i++)
        kaya_tx_add_child(&tx, W_ROOT, W_PICK + i);
    kaya_tx_mount(&tx, 0, W_ROOT);
    kaya_submit(tx.buf, tx.len);
}

/* `file_dialog_result`, three values per file (crates/kaya/src/spec.rs
 * kind 14): the generator emits no parser, so the floor reads the body. */
static int parse_picked(const uint8_t *rec, uint32_t *count, uint64_t *handle) {
    const KayaRecordHeader *h = (const KayaRecordHeader *)rec;
    if (h->kind != KAYA_OCCURRENCE_FILE_DIALOG_RESULT)
        return 0;
    size_t at = sizeof(KayaRecordHeader) + 8;
    memcpy(count, rec + at, 4);
    at += 4 + 4 + 8;
    *handle = 0;
    if (*count > 0) {
        KayaVal v;
        kaya_parse_value(rec, at, &v);
        *handle = (uint64_t)v.i;
    }
    return 1;
}

static void *app(void *arg) {
    (void)arg;
    build_scene();
    char said[512];
    if (saved[0]) {
        read_back(saved, said, sizeof said, NULL, 0);
        status(said);
    }
    const uint8_t *rec;
    for (;;) {
        size_t size = kaya_next_occurrence(&rec);
        if (size == 0)
            break; /* shutdown */
        if (size == KAYA_OCCURRENCE_WOKEN)
            continue;
        uint64_t id, handle;
        uint32_t n_keys, count;
        KayaVal keys[1];
        if (kaya_parse_click(rec, &id, keys, 1, &n_keys)) {
            if (id == W_PICK) {
                uint8_t buf[256];
                KayaTx tx = {buf, 0, sizeof buf};
                kaya_tx_show_file_dialog(&tx, 0, DIALOG, 0, KAYA_FILE_CONTENT_ANY, NULL, 0);
                kaya_submit(tx.buf, tx.len);
            } else if (id == W_FOREIGN) {
                read_back("kaya-ref1:beos:AAAA:00000000", said, sizeof said, NULL, 0);
                status(said);
            } else if (id == W_DELETE) {
                char path[1024] = "";
                read_back(saved, said, sizeof said, path, sizeof path);
                if (path[0])
                    unlink(path);
                read_back(saved, said, sizeof said, NULL, 0);
                status(said);
            }
        } else if (parse_picked(rec, &count, &handle)) {
            if (count == 0) {
                status("cancelled");
                continue;
            }
            char token[8192];
            size_t len = 0;
            uint32_t code = kaya_reference_mint(handle, (uint8_t *)token, sizeof token - 1, &len);
            token[len < sizeof token ? len : sizeof token - 1] = 0;
            if (code != 0) {
                fprintf(stderr, "references: %s\n", token);
                status(code < 6 ? REFUSALS[code] : "refused");
                continue;
            }
            kaya_session_set_string(SCOPE_APP, 0, (const uint8_t *)"doc", 3, (const uint8_t *)token, len);
            status("minted");
        }
    }
    return NULL;
}

int main(void) {
    if (kaya_spec_hash() != KAYA_SPEC_HASH) {
        fprintf(stderr, "kaya: library/binding spec mismatch — rebuild both\n");
        return 1;
    }
    const char *tmp = getenv("TMPDIR");
    char dir[1024];
    snprintf(dir, sizeof dir, "%s/kaya-refs-%d", tmp && *tmp ? tmp : "/tmp", (int)getpid());
    if (mkdir(dir, 0755) != 0 && errno != EEXIST)
        fprintf(stderr, "references: cannot make %s: %s\n", dir, strerror(errno));
    write_scene_file(dir, "picked.txt", "picked bytes");
    write_scene_file(dir, "decoy.txt", "decoy");
    size_t len = 0;
    if (kaya_session_get_string(SCOPE_APP, 0, (const uint8_t *)"doc", 3, (uint8_t *)saved, sizeof saved - 1, &len) == 0)
        len = 0;
    saved[len < sizeof saved ? len : sizeof saved - 1] = 0;
    pthread_t app_thread;
    pthread_create(&app_thread, NULL, app, NULL);
    return kaya_run(); /* takes over the main thread until the app exits */
}
