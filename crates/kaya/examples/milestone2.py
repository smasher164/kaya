"""The milestone-2 scene from the other side of the C ABI (function floor).

The host language's main thread enters kaya_run() and becomes the core's
UI thread. A Python thread is the app thread: it drains occurrences and
answers with packed transaction records through kaya_submit. The scene
declares a When (the extras banner) and a nested For (groups holding
items); clicks on stamped remove buttons come back as a template node id
plus key path, and the app answers by removing that entry — the screen
follows the data.

Build the library first (cargo build), then:
    KAYA_SELFTEST=1 python3 crates/kaya/examples/milestone2.py
On Windows, ensure the directory holding kaya.dll and the bootstrap DLL
is on PATH (or run from that directory).
"""

import ctypes
import os
import pathlib
import struct
import sys
import threading


def find_library():
    if lib := os.environ.get("KAYA_LIB"):
        return lib
    name = {"darwin": "libkaya.dylib", "win32": "kaya.dll"}.get(
        sys.platform, "libkaya.so"
    )
    here = pathlib.Path(__file__).resolve().parent
    candidates = [here / name]
    if len(here.parents) > 2:  # repo root when run in-tree
        candidates.append(here.parents[2] / "target" / "debug" / name)
    for path in candidates:
        if path.exists():
            return str(path)
    raise FileNotFoundError(f"{name} not found; build with cargo or set KAYA_LIB")


lib = ctypes.CDLL(find_library())

lib.kaya_next_occurrence.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
lib.kaya_next_occurrence.restype = ctypes.c_size_t
lib.kaya_submit.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
lib.kaya_submit.restype = None
lib.kaya_run.restype = ctypes.c_int32

BUTTON_CLICKED = 1

# KAYA_TX_* record kinds and value/source tags from kaya.h.
TX_CREATE_SIGNAL = 1
TX_WRITE_SIGNAL = 2
TX_CREATE_WIDGET = 3
TX_SET_PROPERTY = 4
TX_ADD_CHILD = 5
TX_MOUNT = 6
TX_CREATE_COLLECTION = 7
TX_COLLECTION_INSERT = 8
TX_COLLECTION_UPDATE = 9
TX_COLLECTION_REMOVE = 10
TX_CREATE_FOR = 11
TX_CREATE_WHEN = 12
TX_TEMPLATE_END = 13
KIND_COLUMN = 1
KIND_BUTTON = 2
KIND_LABEL = 3
PROP_TEXT = 1
SOURCE_CONST = 0
SOURCE_SIGNAL = 1
SOURCE_ELEMENT = 2
VALUE_BOOL = 1
VALUE_STR = 4

# Guest-allocated ids, counted from 1 per space.
SIG_STATUS = 1
SIG_EXTRAS = 2
W_COLUMN = 1
W_STEP = 2
W_STATUS = 3
W_WHEN = 4
W_FOR_GROUPS = 5
C_GROUPS = 1
C_ITEMS = 2
N_BANNER = 1
N_GROUP_COL = 2
N_GROUP_NAME = 3
N_ITEMS_FOR = 4
N_ITEM_ROW = 5
N_ITEM_TEXT = 6
N_REMOVE = 7


def record(kind, body):
    """One packed record: {u32 size, u16 kind, u16 flags}, body, pad to 8."""
    size = 8 + len(body)
    padded = (size + 7) & ~7
    return struct.pack("<IHH", padded, kind, 0) + body + b"\0" * (padded - size)


def str_value(text):
    utf8 = text.encode()
    padded = (len(utf8) + 7) & ~7
    return struct.pack("<II", VALUE_STR, len(utf8)) + utf8 + b"\0" * (padded - len(utf8))


def bool_value(v):
    return struct.pack("<II", VALUE_BOOL, 1) + bytes([1 if v else 0]) + b"\0" * 7


def path(*keys):
    """A key path: {u32 count, u32 reserved, count values}."""
    return struct.pack("<II", len(keys), 0) + b"".join(str_value(k) for k in keys)


def scene_tx():
    return b"".join([
        record(TX_CREATE_SIGNAL, struct.pack("<Q", SIG_STATUS) + str_value("step 0")),
        record(TX_CREATE_SIGNAL, struct.pack("<Q", SIG_EXTRAS) + bool_value(False)),
        record(TX_CREATE_WIDGET, struct.pack("<QII", W_COLUMN, KIND_COLUMN, 0)),
        record(TX_CREATE_WIDGET, struct.pack("<QII", W_STEP, KIND_BUTTON, 0)),
        record(TX_SET_PROPERTY,
               struct.pack("<QII", W_STEP, PROP_TEXT, SOURCE_CONST) + str_value("step")),
        record(TX_CREATE_WIDGET, struct.pack("<QII", W_STATUS, KIND_LABEL, 0)),
        record(TX_SET_PROPERTY,
               struct.pack("<QIIQ", W_STATUS, PROP_TEXT, SOURCE_SIGNAL, SIG_STATUS)),
        # When(extras): a banner label. The scope brackets the blueprint.
        record(TX_CREATE_WHEN, struct.pack("<QQ", W_WHEN, SIG_EXTRAS)),
        record(TX_CREATE_WIDGET, struct.pack("<QII", N_BANNER, KIND_LABEL, 0)),
        record(TX_SET_PROPERTY,
               struct.pack("<QII", N_BANNER, PROP_TEXT, SOURCE_CONST) + str_value("extras on")),
        record(TX_TEMPLATE_END, b""),
        # For over groups, nesting a For over items.
        record(TX_CREATE_COLLECTION, struct.pack("<Q", C_GROUPS)),
        record(TX_CREATE_FOR, struct.pack("<QQ", W_FOR_GROUPS, C_GROUPS)),
        record(TX_CREATE_WIDGET, struct.pack("<QII", N_GROUP_COL, KIND_COLUMN, 0)),
        record(TX_CREATE_WIDGET, struct.pack("<QII", N_GROUP_NAME, KIND_LABEL, 0)),
        record(TX_SET_PROPERTY,
               struct.pack("<QIIII", N_GROUP_NAME, PROP_TEXT, SOURCE_ELEMENT, 0, 0)),
        record(TX_ADD_CHILD, struct.pack("<QQ", N_GROUP_COL, N_GROUP_NAME)),
        record(TX_CREATE_COLLECTION, struct.pack("<Q", C_ITEMS)),
        record(TX_CREATE_FOR, struct.pack("<QQ", N_ITEMS_FOR, C_ITEMS)),
        record(TX_CREATE_WIDGET, struct.pack("<QII", N_ITEM_ROW, KIND_COLUMN, 0)),
        record(TX_CREATE_WIDGET, struct.pack("<QII", N_ITEM_TEXT, KIND_LABEL, 0)),
        record(TX_SET_PROPERTY,
               struct.pack("<QIIII", N_ITEM_TEXT, PROP_TEXT, SOURCE_ELEMENT, 0, 0)),
        record(TX_CREATE_WIDGET, struct.pack("<QII", N_REMOVE, KIND_BUTTON, 0)),
        record(TX_SET_PROPERTY,
               struct.pack("<QII", N_REMOVE, PROP_TEXT, SOURCE_CONST) + str_value("remove")),
        record(TX_ADD_CHILD, struct.pack("<QQ", N_ITEM_ROW, N_ITEM_TEXT)),
        record(TX_ADD_CHILD, struct.pack("<QQ", N_ITEM_ROW, N_REMOVE)),
        record(TX_TEMPLATE_END, b""),
        record(TX_ADD_CHILD, struct.pack("<QQ", N_GROUP_COL, N_ITEMS_FOR)),
        record(TX_TEMPLATE_END, b""),
        record(TX_ADD_CHILD, struct.pack("<QQ", W_COLUMN, W_STEP)),
        record(TX_ADD_CHILD, struct.pack("<QQ", W_COLUMN, W_STATUS)),
        record(TX_ADD_CHILD, struct.pack("<QQ", W_COLUMN, W_WHEN)),
        record(TX_ADD_CHILD, struct.pack("<QQ", W_COLUMN, W_FOR_GROUPS)),
        record(TX_MOUNT, struct.pack("<QQ", 0, W_COLUMN)),  # window 0: the default
    ])


def insert(collection, at, key, value):
    return record(TX_COLLECTION_INSERT,
                  struct.pack("<Q", collection) + path(*at) + str_value(key) + str_value(value))


def update(collection, at, key, value):
    return record(TX_COLLECTION_UPDATE,
                  struct.pack("<Q", collection) + path(*at) + str_value(key) + str_value(value))


def remove(collection, at, key):
    return record(TX_COLLECTION_REMOVE,
                  struct.pack("<Q", collection) + path(*at) + str_value(key))


def write_str(signal, text):
    return record(TX_WRITE_SIGNAL, struct.pack("<Q", signal) + str_value(text))


def write_bool(signal, v):
    return record(TX_WRITE_SIGNAL, struct.pack("<Q", signal) + bool_value(v))


def submit(tx):
    lib.kaya_submit(tx, len(tx))


def parse_occurrence(buf, size):
    """One record: header, then u64 id, u32 path_len, u32 pad, values."""
    _size, kind, _flags = struct.unpack_from("<IHH", buf, 0)
    if kind != BUTTON_CLICKED:
        return None
    ident, path_len = struct.unpack_from("<QI", buf, 8)
    keys = []
    at = 24
    for _ in range(path_len):
        vtype, vlen = struct.unpack_from("<II", buf, at)
        assert vtype == VALUE_STR, "this scene's keys are strings"
        keys.append(buf[at + 8:at + 8 + vlen].decode())
        at += 8 + ((vlen + 7) & ~7)
    return ident, keys


def app():
    submit(scene_tx())
    steps = 0
    buf = ctypes.create_string_buffer(256)
    while True:
        size = lib.kaya_next_occurrence(buf, 256)
        if size == 0:
            break  # shutdown
        parsed = parse_occurrence(buf.raw, size)
        if parsed is None:
            continue
        ident, keys = parsed
        if not keys and ident == W_STEP:
            steps += 1
            tx = b""
            if steps == 1:
                tx += insert(C_GROUPS, [], "g1", "Work")
                tx += insert(C_ITEMS, ["g1"], "a", "send report")
                tx += insert(C_ITEMS, ["g1"], "b", "buy milk")
            elif steps == 2:
                tx += insert(C_GROUPS, [], "g2", "Home")
                tx += insert(C_ITEMS, ["g2"], "a", "water plants")
                tx += update(C_GROUPS, [], "g1", "Office")
            tx += write_bool(SIG_EXTRAS, steps == 1)
            tx += write_str(SIG_STATUS, f"step {steps}")
            submit(tx)
        elif len(keys) == 2 and ident == N_REMOVE:
            group, item = keys
            submit(remove(C_ITEMS, [group], item)
                   + write_str(SIG_STATUS, f"removed {group}/{item}"))


# Not a daemon thread: after kaya_run returns, the core has signalled
# Shutdown, so the app loop ends and the join completes. Exiting while a
# daemon thread re-enters Python during interpreter finalization crashes.
app_thread = threading.Thread(target=app)
app_thread.start()
code = lib.kaya_run()  # takes over the main thread until the app exits
app_thread.join()
sys.exit(code)
