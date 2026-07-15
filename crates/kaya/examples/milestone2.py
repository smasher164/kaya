"""The milestone-2 scene from Python, on the kaya bindings.

The wire vocabulary (kaya_wire) is generated from kaya::spec by
kaya-bindgen; the runtime (kaya) is the hand-written loading and
occurrence loop. What remains here is what an app actually is: the
scene declaration and the logic answering occurrences.

Build the library first (cargo build), then:
    KAYA_SELFTEST=1 python3 crates/kaya/examples/milestone2.py
"""

import pathlib
import sys
import threading

_here = pathlib.Path(__file__).resolve().parent
for _base in [_here, *_here.parents]:
    if (_base / "bindings" / "python").is_dir():
        sys.path.insert(0, str(_base / "bindings" / "python"))
        break

import kaya
from kaya_wire import (
    KIND_BUTTON,
    KIND_COLUMN,
    KIND_LABEL,
    tx_add_child,
    tx_bind_text,
    tx_bind_text_element,
    tx_collection_insert,
    tx_collection_remove,
    tx_collection_update,
    tx_create_collection,
    tx_create_for,
    tx_create_when,
    tx_create_signal,
    tx_create_widget,
    tx_mount,
    tx_set_text,
    tx_template_end,
    tx_write_signal,
)

# Guest-allocated ids, counted from 1 per space.
SIG_STATUS, SIG_EXTRAS = 1, 2
W_COLUMN, W_STEP, W_STATUS, W_WHEN, W_FOR_GROUPS = 1, 2, 3, 4, 5
C_GROUPS, C_ITEMS = 1, 2
N_BANNER, N_GROUP_COL, N_GROUP_NAME, N_ITEMS_FOR = 1, 2, 3, 4
N_ITEM_ROW, N_ITEM_TEXT, N_REMOVE = 5, 6, 7


def build_scene():
    kaya.submit(
        tx_create_signal(SIG_STATUS, "step 0"),
        tx_create_signal(SIG_EXTRAS, False),
        tx_create_widget(W_COLUMN, KIND_COLUMN),
        tx_create_widget(W_STEP, KIND_BUTTON),
        tx_set_text(W_STEP, "step"),
        tx_create_widget(W_STATUS, KIND_LABEL),
        tx_bind_text(W_STATUS, SIG_STATUS),
        # When(extras): a banner label.
        tx_create_when(W_WHEN, SIG_EXTRAS),
        tx_create_widget(N_BANNER, KIND_LABEL),
        tx_set_text(N_BANNER, "extras on"),
        tx_template_end(),
        # For over groups, nesting a For over items.
        tx_create_collection(C_GROUPS),
        tx_create_for(W_FOR_GROUPS, C_GROUPS),
        tx_create_widget(N_GROUP_COL, KIND_COLUMN),
        tx_create_widget(N_GROUP_NAME, KIND_LABEL),
        tx_bind_text_element(N_GROUP_NAME),
        tx_add_child(N_GROUP_COL, N_GROUP_NAME),
        tx_create_collection(C_ITEMS),
        tx_create_for(N_ITEMS_FOR, C_ITEMS),
        tx_create_widget(N_ITEM_ROW, KIND_COLUMN),
        tx_create_widget(N_ITEM_TEXT, KIND_LABEL),
        tx_bind_text_element(N_ITEM_TEXT),
        tx_create_widget(N_REMOVE, KIND_BUTTON),
        tx_set_text(N_REMOVE, "remove"),
        tx_add_child(N_ITEM_ROW, N_ITEM_TEXT),
        tx_add_child(N_ITEM_ROW, N_REMOVE),
        tx_template_end(),
        tx_add_child(N_GROUP_COL, N_ITEMS_FOR),
        tx_template_end(),
        tx_add_child(W_COLUMN, W_STEP),
        tx_add_child(W_COLUMN, W_STATUS),
        tx_add_child(W_COLUMN, W_WHEN),
        tx_add_child(W_COLUMN, W_FOR_GROUPS),
        tx_mount(0, W_COLUMN),  # window 0: the default
    )


def app():
    build_scene()
    steps = 0
    while occurrence := kaya.next_occurrence():
        ident, keys = occurrence
        if not keys and ident == W_STEP:
            steps += 1
            changes = []
            if steps == 1:
                changes = [
                    tx_collection_insert(C_GROUPS, [], "g1", "Work"),
                    tx_collection_insert(C_ITEMS, ["g1"], "a", "send report"),
                    tx_collection_insert(C_ITEMS, ["g1"], "b", "buy milk"),
                ]
            elif steps == 2:
                changes = [
                    tx_collection_insert(C_GROUPS, [], "g2", "Home"),
                    tx_collection_insert(C_ITEMS, ["g2"], "a", "water plants"),
                    tx_collection_update(C_GROUPS, [], "g1", "Office"),
                ]
            kaya.submit(
                *changes,
                tx_write_signal(SIG_EXTRAS, steps == 1),
                tx_write_signal(SIG_STATUS, f"step {steps}"),
            )
        elif len(keys) == 2 and ident == N_REMOVE:
            group, item = keys
            kaya.submit(
                tx_collection_remove(C_ITEMS, [group], item),
                tx_write_signal(SIG_STATUS, f"removed {group}/{item}"),
            )


# Not a daemon thread: after run() returns, the core has signalled
# Shutdown, so the app loop ends and the join completes.
app_thread = threading.Thread(target=app)
app_thread.start()
code = kaya.run()  # takes over the main thread until the app exits
app_thread.join()
sys.exit(code)
