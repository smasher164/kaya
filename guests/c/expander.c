/* The expander scene (tools/scenes/expander.steps; docs/expander-plan.md §5)
 * on the floor: kind 26 with its header props (text, summary, symbol,
 * expanded) and its body children declared one by one, a stamped copy's
 * expanded state bound to the row's Bool field (K10). */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* Guest-allocated ids; tools/check-c-ids.py holds the one id space. */
#define W_ROOT 1
#define W_DETAILS 2
#define W_NAME 3
#define W_INSIDE 4
#define W_STATE 5
#define W_HEARD 6
#define W_TYPED 7
#define W_BUTTONS 8
#define W_SHOW 9
#define W_HIDE 10
#define W_FORM 11
#define W_SORT_ROW 12
#define W_SORT_LABEL 13
#define W_SORT 14
#define W_DUE 15
#define W_BY_NAME 16
#define W_ADVANCED 17
#define W_BADGE_ROW 18
#define W_BADGE_LABEL 19
#define W_BADGE 20
#define W_KEEP_ROW 21
#define W_KEEP_LABEL 22
#define W_KEEP 23
#define W_ROWS 24
#define W_REBUILD 25
#define W_LIST 26
#define W_FOR_SECTIONS 27
#define N_SECTION 28
#define N_SECTION_NAME 29

#define SIG_STATE 1
#define SIG_HEARD 2
#define SIG_TYPED 3
#define SIG_ROWS 4
#define SIG_INSIDE 5

#define C_SECTIONS 1
#define F_NAME 0
#define F_OPEN 1

/* Packed by hand: the generated setter closes the record BEFORE the value. */
static void window_prop(KayaTx *tx, uint32_t prop, KayaVal value) {
    size_t start = kaya_wire_begin(tx, KAYA_TX_SET_WINDOW_PROP);
    kaya_wire_u64(tx, 0);
    kaya_wire_u32(tx, prop);
    kaya_wire_u32(tx, KAYA_SOURCE_CONST);
    kaya_wire_value(tx, value);
    kaya_wire_end(tx, start);
}

static void insert_section(KayaTx *tx, const char *key, const char *name, int open) {
    kaya_tx_collection_insert(tx, C_SECTIONS, 0, 0, kaya_str(key), 0,
                              (KayaVal[]){kaya_str(name), kaya_bool(open)}, 2);
}

static void build_scene(void) {
    uint8_t buf[8192];
    KayaTx tx = {buf, 0, sizeof buf};

    window_prop(&tx, KAYA_WPROP_TITLE, kaya_str("expander"));
    window_prop(&tx, KAYA_WPROP_WIDTH, kaya_f64(520.0));
    window_prop(&tx, KAYA_WPROP_HEIGHT, kaya_f64(860.0));

    kaya_tx_create_signal(&tx, SIG_STATE, kaya_str("details: closed"));
    kaya_tx_create_signal(&tx, SIG_HEARD, kaya_str("heard: 0"));
    kaya_tx_create_signal(&tx, SIG_TYPED, kaya_str("name: -"));
    kaya_tx_create_signal(&tx, SIG_ROWS, kaya_str("rows: -"));
    kaya_tx_create_signal(&tx, SIG_INSIDE, kaya_str("Inside the body"));

    kaya_tx_create_widget(&tx, W_ROOT, KAYA_KIND_COLUMN);

    kaya_tx_create_widget(&tx, W_DETAILS, KAYA_KIND_EXPANDER);
    kaya_tx_create_widget(&tx, W_NAME, KAYA_KIND_ENTRY);
    kaya_tx_set_placeholder(&tx, W_NAME, "Name");
    kaya_tx_set_a11y_id(&tx, W_NAME, "name");
    kaya_tx_add_child(&tx, W_DETAILS, W_NAME);
    kaya_tx_create_widget(&tx, W_INSIDE, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_INSIDE, SIG_INSIDE);
    kaya_tx_set_a11y_id(&tx, W_INSIDE, "inside");
    kaya_tx_add_child(&tx, W_DETAILS, W_INSIDE);
    kaya_tx_set_text(&tx, W_DETAILS, "Details");
    kaya_tx_set_summary(&tx, W_DETAILS, "One field");
    kaya_tx_set_symbol(&tx, W_DETAILS, KAYA_SYMBOL_INFO);
    kaya_tx_set_a11y_id(&tx, W_DETAILS, "details");
    kaya_tx_add_child(&tx, W_ROOT, W_DETAILS);

    kaya_tx_create_widget(&tx, W_STATE, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_STATE, SIG_STATE);
    kaya_tx_set_a11y_id(&tx, W_STATE, "state");
    kaya_tx_add_child(&tx, W_ROOT, W_STATE);
    kaya_tx_create_widget(&tx, W_HEARD, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_HEARD, SIG_HEARD);
    kaya_tx_set_a11y_id(&tx, W_HEARD, "heard");
    kaya_tx_add_child(&tx, W_ROOT, W_HEARD);
    kaya_tx_create_widget(&tx, W_TYPED, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_TYPED, SIG_TYPED);
    kaya_tx_set_a11y_id(&tx, W_TYPED, "typed");
    kaya_tx_add_child(&tx, W_ROOT, W_TYPED);

    kaya_tx_create_widget(&tx, W_BUTTONS, KAYA_KIND_ROW);
    kaya_tx_create_widget(&tx, W_SHOW, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_SHOW, "Show");
    kaya_tx_set_a11y_id(&tx, W_SHOW, "show");
    kaya_tx_add_child(&tx, W_BUTTONS, W_SHOW);
    kaya_tx_create_widget(&tx, W_HIDE, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_HIDE, "Hide");
    kaya_tx_set_a11y_id(&tx, W_HIDE, "hide");
    kaya_tx_add_child(&tx, W_BUTTONS, W_HIDE);
    kaya_tx_add_child(&tx, W_ROOT, W_BUTTONS);

    kaya_tx_create_widget(&tx, W_FORM, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, W_SORT_ROW, KAYA_KIND_LABELED);
    kaya_tx_create_widget(&tx, W_SORT_LABEL, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, W_SORT_LABEL, "Sort");
    kaya_tx_add_child(&tx, W_SORT_ROW, W_SORT_LABEL);
    kaya_tx_create_widget(&tx, W_SORT, KAYA_KIND_SELECT);
    kaya_tx_create_widget(&tx, W_DUE, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, W_DUE, "Due");
    kaya_tx_add_child(&tx, W_SORT, W_DUE);
    kaya_tx_create_widget(&tx, W_BY_NAME, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, W_BY_NAME, "Name");
    kaya_tx_add_child(&tx, W_SORT, W_BY_NAME);
    kaya_tx_set_value(&tx, W_SORT, 0.0);
    kaya_tx_set_a11y_id(&tx, W_SORT, "sort");
    kaya_tx_add_child(&tx, W_SORT_ROW, W_SORT);
    kaya_tx_add_child(&tx, W_FORM, W_SORT_ROW);
    kaya_tx_create_widget(&tx, W_ADVANCED, KAYA_KIND_EXPANDER);
    kaya_tx_create_widget(&tx, W_BADGE_ROW, KAYA_KIND_LABELED);
    kaya_tx_create_widget(&tx, W_BADGE_LABEL, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, W_BADGE_LABEL, "Hide badge");
    kaya_tx_add_child(&tx, W_BADGE_ROW, W_BADGE_LABEL);
    kaya_tx_create_widget(&tx, W_BADGE, KAYA_KIND_CHECKBOX);
    kaya_tx_set_text(&tx, W_BADGE, "");
    kaya_tx_set_a11y_id(&tx, W_BADGE, "badge");
    kaya_tx_add_child(&tx, W_BADGE_ROW, W_BADGE);
    kaya_tx_add_child(&tx, W_ADVANCED, W_BADGE_ROW);
    kaya_tx_create_widget(&tx, W_KEEP_ROW, KAYA_KIND_LABELED);
    kaya_tx_create_widget(&tx, W_KEEP_LABEL, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, W_KEEP_LABEL, "Keep completed");
    kaya_tx_add_child(&tx, W_KEEP_ROW, W_KEEP_LABEL);
    kaya_tx_create_widget(&tx, W_KEEP, KAYA_KIND_CHECKBOX);
    kaya_tx_set_text(&tx, W_KEEP, "");
    kaya_tx_set_a11y_id(&tx, W_KEEP, "keep");
    kaya_tx_add_child(&tx, W_KEEP_ROW, W_KEEP);
    kaya_tx_add_child(&tx, W_ADVANCED, W_KEEP_ROW);
    kaya_tx_set_text(&tx, W_ADVANCED, "Advanced");
    kaya_tx_set_a11y_id(&tx, W_ADVANCED, "advanced");
    kaya_tx_add_child(&tx, W_FORM, W_ADVANCED);
    kaya_tx_set_a11y_id(&tx, W_FORM, "form");
    kaya_tx_add_child(&tx, W_ROOT, W_FORM);

    kaya_tx_create_widget(&tx, W_ROWS, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_ROWS, SIG_ROWS);
    kaya_tx_set_a11y_id(&tx, W_ROWS, "rows");
    kaya_tx_add_child(&tx, W_ROOT, W_ROWS);
    kaya_tx_create_widget(&tx, W_REBUILD, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_REBUILD, "Rebuild");
    kaya_tx_set_a11y_id(&tx, W_REBUILD, "rebuild");
    kaya_tx_add_child(&tx, W_ROOT, W_REBUILD);

    kaya_tx_create_widget(&tx, W_LIST, KAYA_KIND_COLUMN);
    kaya_tx_create_collection(
        &tx, C_SECTIONS,
        (KayaVariantSchema[]){{(uint32_t[]){KAYA_VALUE_STR, KAYA_VALUE_BOOL}, 2}}, 1);
    kaya_tx_create_for(&tx, W_FOR_SECTIONS, C_SECTIONS);
    kaya_tx_create_widget(&tx, N_SECTION, KAYA_KIND_EXPANDER);
    kaya_tx_create_widget(&tx, N_SECTION_NAME, KAYA_KIND_LABEL);
    kaya_tx_bind_text_element(&tx, N_SECTION_NAME, 0, F_NAME);
    kaya_tx_add_child(&tx, N_SECTION, N_SECTION_NAME);
    kaya_tx_bind_text_element(&tx, N_SECTION, 0, F_NAME);
    kaya_tx_bind_expanded_element(&tx, N_SECTION, 0, F_OPEN);
    kaya_tx_set_a11y_id(&tx, N_SECTION, "sec");
    kaya_tx_template_end(&tx);
    kaya_tx_add_child(&tx, W_LIST, W_FOR_SECTIONS);
    kaya_tx_add_child(&tx, W_ROOT, W_LIST);

    kaya_tx_mount(&tx, 0, W_ROOT); /* window 0: the default */

    insert_section(&tx, "s00", "Section 0", 0);
    insert_section(&tx, "s01", "Section 1", 1);
    insert_section(&tx, "s02", "Section 2", 0);

    kaya_submit(tx.buf, tx.len);
}

static const char *word(int open) { return open ? "open" : "closed"; }

static void *app(void *arg) {
    (void)arg;
    build_scene();
    unsigned heard = 0;
    int s00_open = 0;
    const uint8_t *rec;
    for (;;) {
        size_t size = kaya_next_occurrence(&rec);
        if (size == 0)
            break; /* shutdown */
        if (size == KAYA_OCCURRENCE_WOKEN)
            continue; /* no record; rec is NULL */
        uint64_t id;
        KayaVal keys[2], payload;
        uint32_t n_keys;
        uint8_t buf[512];
        KayaTx tx = {buf, 0, sizeof buf};
        char text[160];
        if (kaya_parse_toggled(rec, &id, keys, 2, &n_keys, &payload)) {
            int open = payload.i != 0;
            if (id == W_DETAILS && n_keys == 0) {
                heard += 1;
                snprintf(text, sizeof text, "details: %s", word(open));
                kaya_tx_write_signal(&tx, SIG_STATE, kaya_str(text));
                snprintf(text, sizeof text, "heard: %u", heard);
                kaya_tx_write_signal(&tx, SIG_HEARD, kaya_str(text));
            } else if (id == N_SECTION && n_keys == 1) {
                /* A parsed Str is NOT terminated: its length bounds the copy. */
                char key[32];
                snprintf(key, sizeof key, "%.*s", (int)keys[0].s_len, keys[0].s);
                if (strcmp(key, "s00") == 0)
                    s00_open = open;
                kaya_tx_collection_update_field(&tx, C_SECTIONS, 0, 0, kaya_str(key), F_OPEN, 0,
                                                kaya_bool(open));
                snprintf(text, sizeof text, "sec %s: %s", key, word(open));
                kaya_tx_write_signal(&tx, SIG_ROWS, kaya_str(text));
            }
        } else if (kaya_parse_text_changed(rec, &id, keys, 2, &n_keys, &payload) &&
                   id == W_NAME) {
            snprintf(text, sizeof text, "name: %.*s", (int)payload.s_len, payload.s);
            kaya_tx_write_signal(&tx, SIG_TYPED, kaya_str(text));
        } else if (kaya_parse_click(rec, &id, keys, 2, &n_keys)) {
            if (id == W_SHOW || id == W_HIDE) {
                int open = id == W_SHOW;
                kaya_tx_set_expanded(&tx, W_DETAILS, open);
                snprintf(text, sizeof text, "details: %s", word(open));
                kaya_tx_write_signal(&tx, SIG_STATE, kaya_str(text));
            } else if (id == W_REBUILD) {
                kaya_tx_collection_remove(&tx, C_SECTIONS, 0, 0, kaya_str("s00"));
                insert_section(&tx, "s00", "Section 0", s00_open);
                kaya_tx_write_signal(&tx, SIG_ROWS, kaya_str("rebuilt s00"));
            }
        }
        if (tx.len > 0)
            kaya_submit(tx.buf, tx.len);
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
