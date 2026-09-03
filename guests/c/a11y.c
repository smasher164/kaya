/* The a11y conformance scene (tools/scenes/a11y.steps).
 * EXACTLY ONE CONTAINER OF EACH KIND: container targets are ordinal. */

#include <kaya.h>
#include <kaya_wire.h>

#include <pthread.h>
#include <stdio.h>

/* Guest-allocated ids; tools/check-c-ids.py holds the one id space. */
#define W_FORM 1
#define W_SAVE 2
#define W_DETAILS 3
#define W_RESET 4
#define W_STATUS 5
#define W_NAME 6
#define W_NOTES 7
#define W_VOLUME 8
#define W_LOADING 9
#define W_LOGO 10
#define W_COLOR 11
#define W_COLOR_RED 12
#define W_COLOR_GREEN 13
#define W_SIZE 14
#define W_SIZE_SMALL 15
#define W_SIZE_LARGE 16
#define W_CELLS 17
#define W_CELL_NAME 18
#define W_CELL_VALUE 19
#define W_FEED 20
#define W_FEED_ITEM 21
#define W_ACTIONS 22
#define W_CANCEL 23
#define W_OK 24
#define W_SPOKEN 25
#define W_RENAME 26
#define SIG_SPOKEN 1

/* A 2x2 RGB PNG (red/green over blue/white), embedded as source. */
static const uint8_t TEST_PNG[75] = {
    137, 80,  78,  71,  13,  10,  26,  10,  0,   0,   0,   13,  73,
    72,  68,  82,  0,   0,   0,   2,   0,   0,   0,   2,   8,   2,
    0,   0,   0,   253, 212, 154, 115, 0,   0,   0,   18,  73,  68,
    65,  84,  120, 156, 99,  248, 207, 192, 192, 0,   194, 12,  255,
    129, 0,   0,   31,  238, 5,   251, 11,  217, 104, 139, 0,   0,
    0,   0,   73,  69,  78,  68,  174, 66,  96,  130};

static void build_scene(void) {
    uint8_t buf[4096];
    KayaTx tx = {buf, 0, sizeof buf};

    kaya_tx_create_widget(&tx, W_FORM, KAYA_KIND_COLUMN);
    kaya_tx_set_a11y_id(&tx, W_FORM, "form");
    kaya_tx_set_a11y_label(&tx, W_FORM, "Form");

    /* Deliberately NOT labelled: the platform must speak the caption. */
    kaya_tx_create_widget(&tx, W_SAVE, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_SAVE, "Save");
    kaya_tx_set_a11y_id(&tx, W_SAVE, "save");
    kaya_tx_set_a11y_hint(&tx, W_SAVE, "save the draft");
    kaya_tx_create_widget(&tx, W_DETAILS, KAYA_KIND_CHECKBOX);
    kaya_tx_set_text(&tx, W_DETAILS, "Details");
    kaya_tx_set_a11y_id(&tx, W_DETAILS, "details");
    kaya_tx_set_a11y_hint(&tx, W_DETAILS, "show more detail");
    kaya_tx_create_widget(&tx, W_RESET, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_RESET, "Reset");
    kaya_tx_set_a11y_id(&tx, W_RESET, "reset");
    kaya_tx_create_widget(&tx, W_STATUS, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, W_STATUS, "Ready");
    kaya_tx_set_a11y_id(&tx, W_STATUS, "status");

    kaya_tx_create_widget(&tx, W_NAME, KAYA_KIND_ENTRY);
    kaya_tx_set_a11y_id(&tx, W_NAME, "name");
    kaya_tx_set_a11y_label(&tx, W_NAME, "Full name");
    kaya_tx_create_widget(&tx, W_NOTES, KAYA_KIND_TEXTAREA);
    kaya_tx_set_a11y_id(&tx, W_NOTES, "notes");
    kaya_tx_set_a11y_label(&tx, W_NOTES, "Notes");
    kaya_tx_create_widget(&tx, W_VOLUME, KAYA_KIND_SLIDER);
    kaya_tx_set_min(&tx, W_VOLUME, 0.0);
    kaya_tx_set_max(&tx, W_VOLUME, 1.0);
    kaya_tx_set_value(&tx, W_VOLUME, 0.5);
    kaya_tx_set_a11y_id(&tx, W_VOLUME, "volume");
    kaya_tx_set_a11y_label(&tx, W_VOLUME, "Volume");
    kaya_tx_create_widget(&tx, W_LOADING, KAYA_KIND_PROGRESS);
    kaya_tx_set_value(&tx, W_LOADING, 0.25);
    kaya_tx_set_a11y_id(&tx, W_LOADING, "loading");
    kaya_tx_set_a11y_label(&tx, W_LOADING, "Loading");
    kaya_tx_create_widget(&tx, W_LOGO, KAYA_KIND_IMAGE);
    kaya_tx_set_source(&tx, W_LOGO, kaya_blob_register(TEST_PNG, sizeof TEST_PNG));
    kaya_tx_set_a11y_id(&tx, W_LOGO, "logo");
    kaya_tx_set_a11y_label(&tx, W_LOGO, "Logo");

    kaya_tx_create_widget(&tx, W_COLOR, KAYA_KIND_SELECT);
    kaya_tx_create_widget(&tx, W_COLOR_RED, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, W_COLOR_RED, "Red");
    kaya_tx_create_widget(&tx, W_COLOR_GREEN, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, W_COLOR_GREEN, "Green");
    kaya_tx_add_child(&tx, W_COLOR, W_COLOR_RED);
    kaya_tx_add_child(&tx, W_COLOR, W_COLOR_GREEN);
    kaya_tx_set_value(&tx, W_COLOR, 0.0);
    kaya_tx_set_a11y_id(&tx, W_COLOR, "color");
    kaya_tx_set_a11y_label(&tx, W_COLOR, "Color");
    kaya_tx_create_widget(&tx, W_SIZE, KAYA_KIND_RADIO);
    kaya_tx_create_widget(&tx, W_SIZE_SMALL, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, W_SIZE_SMALL, "Small");
    kaya_tx_create_widget(&tx, W_SIZE_LARGE, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, W_SIZE_LARGE, "Large");
    kaya_tx_add_child(&tx, W_SIZE, W_SIZE_SMALL);
    kaya_tx_add_child(&tx, W_SIZE, W_SIZE_LARGE);
    kaya_tx_set_value(&tx, W_SIZE, 0.0);
    kaya_tx_set_a11y_id(&tx, W_SIZE, "size");
    kaya_tx_set_a11y_label(&tx, W_SIZE, "Size");

    kaya_tx_create_widget(&tx, W_CELLS, KAYA_KIND_GRID);
    kaya_tx_set_columns(&tx, W_CELLS, 2.0);
    kaya_tx_set_a11y_id(&tx, W_CELLS, "cells");
    kaya_tx_set_a11y_label(&tx, W_CELLS, "Cells");
    kaya_tx_create_widget(&tx, W_CELL_NAME, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, W_CELL_NAME, "Name");
    kaya_tx_create_widget(&tx, W_CELL_VALUE, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, W_CELL_VALUE, "Ada");
    kaya_tx_add_child(&tx, W_CELLS, W_CELL_NAME);
    kaya_tx_add_child(&tx, W_CELLS, W_CELL_VALUE);

    kaya_tx_create_widget(&tx, W_FEED, KAYA_KIND_SCROLL);
    kaya_tx_set_a11y_id(&tx, W_FEED, "feed");
    kaya_tx_set_a11y_label(&tx, W_FEED, "Feed");
    kaya_tx_create_widget(&tx, W_FEED_ITEM, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, W_FEED_ITEM, "Item");
    kaya_tx_add_child(&tx, W_FEED, W_FEED_ITEM);

    kaya_tx_create_widget(&tx, W_ACTIONS, KAYA_KIND_ROW);
    kaya_tx_set_a11y_id(&tx, W_ACTIONS, "actions");
    kaya_tx_set_a11y_label(&tx, W_ACTIONS, "Actions");
    kaya_tx_create_widget(&tx, W_CANCEL, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_CANCEL, "Cancel");
    kaya_tx_set_a11y_id(&tx, W_CANCEL, "cancel");
    kaya_tx_create_widget(&tx, W_OK, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_OK, "OK");
    kaya_tx_set_a11y_id(&tx, W_OK, "ok");
    kaya_tx_add_child(&tx, W_ACTIONS, W_CANCEL);
    kaya_tx_add_child(&tx, W_ACTIONS, W_OK);

    kaya_tx_create_signal(&tx, SIG_SPOKEN, kaya_str("Before"));
    kaya_tx_create_widget(&tx, W_SPOKEN, KAYA_KIND_LABEL);
    kaya_tx_set_text(&tx, W_SPOKEN, "Spoken");
    kaya_tx_set_a11y_id(&tx, W_SPOKEN, "spoken");
    kaya_tx_bind_a11y_label(&tx, W_SPOKEN, SIG_SPOKEN);
    kaya_tx_create_widget(&tx, W_RENAME, KAYA_KIND_BUTTON);
    kaya_tx_set_text(&tx, W_RENAME, "Rename");
    kaya_tx_set_a11y_id(&tx, W_RENAME, "rename");

    kaya_tx_add_child(&tx, W_FORM, W_SAVE);
    kaya_tx_add_child(&tx, W_FORM, W_DETAILS);
    kaya_tx_add_child(&tx, W_FORM, W_RESET);
    kaya_tx_add_child(&tx, W_FORM, W_STATUS);
    kaya_tx_add_child(&tx, W_FORM, W_NAME);
    kaya_tx_add_child(&tx, W_FORM, W_NOTES);
    kaya_tx_add_child(&tx, W_FORM, W_VOLUME);
    kaya_tx_add_child(&tx, W_FORM, W_LOADING);
    kaya_tx_add_child(&tx, W_FORM, W_LOGO);
    kaya_tx_add_child(&tx, W_FORM, W_COLOR);
    kaya_tx_add_child(&tx, W_FORM, W_SIZE);
    kaya_tx_add_child(&tx, W_FORM, W_CELLS);
    kaya_tx_add_child(&tx, W_FORM, W_FEED);
    kaya_tx_add_child(&tx, W_FORM, W_ACTIONS);
    kaya_tx_add_child(&tx, W_FORM, W_SPOKEN);
    kaya_tx_add_child(&tx, W_FORM, W_RENAME);
    kaya_tx_mount(&tx, 0, W_FORM); /* window 0: the default */

    kaya_submit(tx.buf, tx.len);
}

static void *app(void *arg) {
    (void)arg;
    build_scene();
    const uint8_t *rec;
    for (;;) {
        size_t size = kaya_next_occurrence(&rec);
        if (size == 0)
            break; /* shutdown */
        if (size == KAYA_OCCURRENCE_WOKEN)
            continue; /* no record; rec is NULL */
        uint64_t id;
        KayaVal keys[2];
        uint32_t n_keys;
        if (kaya_parse_click(rec, &id, keys, 2, &n_keys) && id == W_RENAME) {
            uint8_t buf[256];
            KayaTx tx = {buf, 0, sizeof buf};
            kaya_tx_write_signal(&tx, SIG_SPOKEN, kaya_str("After"));
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
