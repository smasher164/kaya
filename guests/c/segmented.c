/* The segmented control scene (tools/scenes/segmented.steps;
 * docs/segmented-plan.md §5) on the floor: kind 25 and its label children
 * declared one by one, the symbol control's labels carrying `symbol`. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* Guest-allocated ids; tools/check-c-ids.py holds the one id space. */
#define W_ROOT 1
#define W_PERIOD 2
#define W_DAY 3
#define W_WEEK 4
#define W_MONTH 5
#define W_PERIOD_TEXT 6
#define W_HEARD_TEXT 7
#define W_RESET 8
#define W_VIEW 9
#define W_INFO 10
#define W_EDIT 11
#define W_VIEW_TEXT 12
#define W_CADENCE_TEXT 13
#define W_FOR_HABITS 14
#define N_HABIT 15
#define N_NAME 16
#define N_CADENCE 17
#define N_DAILY 18
#define N_WEEKLY 19

#define SIG_PERIOD 1
#define SIG_PERIOD_TEXT 2
#define SIG_HEARD_TEXT 3
#define SIG_VIEW_TEXT 4
#define SIG_CADENCE_TEXT 5

#define C_HABITS 1
#define F_NAME 0
#define F_CADENCE 1

static const char *const PERIODS[] = {"Day", "Week", "Month"};
static const char *const VIEWS[] = {"Info", "Edit"};
static const char *const CADENCES[] = {"Daily", "Weekly"};

static void build_scene(void) {
    uint8_t buf[4096];
    KayaTx tx = {buf, 0, sizeof buf};

    kaya_tx_create_signal(&tx, SIG_PERIOD, kaya_f64(0.0));
    kaya_tx_create_signal(&tx, SIG_PERIOD_TEXT, kaya_str("period: Day"));
    kaya_tx_create_signal(&tx, SIG_HEARD_TEXT, kaya_str("heard: 0"));
    kaya_tx_create_signal(&tx, SIG_VIEW_TEXT, kaya_str("view: Edit"));
    kaya_tx_create_signal(&tx, SIG_CADENCE_TEXT, kaya_str("cadence: -"));

    kaya_tx_create_widget(&tx, W_ROOT, KAYA_KIND_COLUMN);

    kaya_tx_create_widget(&tx, W_PERIOD, KAYA_KIND_SEGMENTED);
    kaya_tx_create_widget(&tx, W_DAY, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, W_DAY, "Day");
    kaya_tx_add_child(&tx, W_PERIOD, W_DAY);
    kaya_tx_create_widget(&tx, W_WEEK, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, W_WEEK, "Week");
    kaya_tx_add_child(&tx, W_PERIOD, W_WEEK);
    kaya_tx_create_widget(&tx, W_MONTH, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, W_MONTH, "Month");
    kaya_tx_add_child(&tx, W_PERIOD, W_MONTH);
    kaya_tx_bind_value(&tx, W_PERIOD, SIG_PERIOD);
    kaya_tx_set_a11y_id(&tx, W_PERIOD, "period");
    kaya_tx_set_a11y_label(&tx, W_PERIOD, "Period");
    kaya_tx_add_child(&tx, W_ROOT, W_PERIOD);

    kaya_tx_create_widget(&tx, W_PERIOD_TEXT, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_PERIOD_TEXT, SIG_PERIOD_TEXT);
    kaya_tx_add_child(&tx, W_ROOT, W_PERIOD_TEXT);
    kaya_tx_create_widget(&tx, W_HEARD_TEXT, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_HEARD_TEXT, SIG_HEARD_TEXT);
    kaya_tx_add_child(&tx, W_ROOT, W_HEARD_TEXT);

    kaya_tx_create_widget(&tx, W_RESET, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_RESET, "Reset");
    kaya_tx_set_a11y_id(&tx, W_RESET, "reset");
    kaya_tx_add_child(&tx, W_ROOT, W_RESET);

    kaya_tx_create_widget(&tx, W_VIEW, KAYA_KIND_SEGMENTED);
    kaya_tx_create_widget(&tx, W_INFO, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, W_INFO, "Info");
    kaya_tx_set_symbol(&tx, W_INFO, KAYA_SYMBOL_INFO);
    kaya_tx_add_child(&tx, W_VIEW, W_INFO);
    kaya_tx_create_widget(&tx, W_EDIT, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, W_EDIT, "Edit");
    kaya_tx_set_symbol(&tx, W_EDIT, KAYA_SYMBOL_EDIT);
    kaya_tx_add_child(&tx, W_VIEW, W_EDIT);
    kaya_tx_set_value(&tx, W_VIEW, 1.0);
    kaya_tx_set_a11y_id(&tx, W_VIEW, "view");
    kaya_tx_set_a11y_label(&tx, W_VIEW, "View");
    kaya_tx_add_child(&tx, W_ROOT, W_VIEW);

    kaya_tx_create_widget(&tx, W_VIEW_TEXT, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_VIEW_TEXT, SIG_VIEW_TEXT);
    kaya_tx_add_child(&tx, W_ROOT, W_VIEW_TEXT);
    kaya_tx_create_widget(&tx, W_CADENCE_TEXT, KAYA_KIND_LABEL);
    kaya_tx_bind_text(&tx, W_CADENCE_TEXT, SIG_CADENCE_TEXT);
    kaya_tx_add_child(&tx, W_ROOT, W_CADENCE_TEXT);

    kaya_tx_create_collection(
        &tx, C_HABITS,
        (KayaVariantSchema[]){{(uint32_t[]){KAYA_VALUE_STR, KAYA_VALUE_F64}, 2}}, 1);
    kaya_tx_create_for(&tx, W_FOR_HABITS, C_HABITS);
    kaya_tx_create_widget(&tx, N_HABIT, KAYA_KIND_COLUMN);
    kaya_tx_create_widget(&tx, N_NAME, KAYA_KIND_LABEL);
    kaya_tx_bind_text_element(&tx, N_NAME, 0, F_NAME);
    kaya_tx_add_child(&tx, N_HABIT, N_NAME);
    kaya_tx_create_widget(&tx, N_CADENCE, KAYA_KIND_SEGMENTED);
    kaya_tx_create_widget(&tx, N_DAILY, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, N_DAILY, "Daily");
    kaya_tx_add_child(&tx, N_CADENCE, N_DAILY);
    kaya_tx_create_widget(&tx, N_WEEKLY, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, N_WEEKLY, "Weekly");
    kaya_tx_add_child(&tx, N_CADENCE, N_WEEKLY);
    kaya_tx_bind_value_element(&tx, N_CADENCE, 0, F_CADENCE);
    kaya_tx_set_a11y_id(&tx, N_CADENCE, "cadence");
    kaya_tx_add_child(&tx, N_HABIT, N_CADENCE);
    kaya_tx_template_end(&tx);
    kaya_tx_add_child(&tx, W_ROOT, W_FOR_HABITS);

    kaya_tx_mount(&tx, 0, W_ROOT); /* window 0: the default */

    kaya_tx_collection_insert(&tx, C_HABITS, 0, 0, kaya_str("read"), 0,
                              (KayaVal[]){kaya_str("read"), kaya_f64(1.0)}, 2);
    kaya_tx_collection_insert(&tx, C_HABITS, 0, 0, kaya_str("walk"), 0,
                              (KayaVal[]){kaya_str("walk"), kaya_f64(0.0)}, 2);

    kaya_submit(tx.buf, tx.len);
}

static void *app(void *arg) {
    (void)arg;
    build_scene();
    unsigned heard = 0;
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
        char text[128];
        if (kaya_parse_value_changed(rec, &id, keys, 2, &n_keys, &payload)) {
            int index = (int)payload.f;
            if (id == W_PERIOD && n_keys == 0 && index >= 0 && index < 3) {
                heard += 1;
                kaya_tx_write_signal(&tx, SIG_PERIOD, kaya_f64((double)index));
                snprintf(text, sizeof text, "period: %s", PERIODS[index]);
                kaya_tx_write_signal(&tx, SIG_PERIOD_TEXT, kaya_str(text));
                snprintf(text, sizeof text, "heard: %u", heard);
                kaya_tx_write_signal(&tx, SIG_HEARD_TEXT, kaya_str(text));
            } else if (id == W_VIEW && n_keys == 0 && index >= 0 && index < 2) {
                snprintf(text, sizeof text, "view: %s", VIEWS[index]);
                kaya_tx_write_signal(&tx, SIG_VIEW_TEXT, kaya_str(text));
            } else if (id == N_CADENCE && n_keys == 1 && index >= 0 && index < 2) {
                /* A parsed Str is NOT terminated: its length bounds the copy. */
                snprintf(text, sizeof text, "cadence %.*s: %s", (int)keys[0].s_len,
                         keys[0].s, CADENCES[index]);
                kaya_tx_write_signal(&tx, SIG_CADENCE_TEXT, kaya_str(text));
            }
        } else if (kaya_parse_click(rec, &id, keys, 2, &n_keys) && id == W_RESET) {
            kaya_tx_write_signal(&tx, SIG_PERIOD, kaya_f64(0.0));
            kaya_tx_write_signal(&tx, SIG_PERIOD_TEXT, kaya_str("period: Day"));
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
