"""Milestone 1 from the other side of the C ABI (function floor).

The host language's main thread enters kaya_run() and becomes the core's
UI thread. A Python thread is the app thread: it drains occurrences and
answers with packed transaction records through kaya_submit. The scene
arrives as one transaction; the label's text is a signal binding this
guest writes on every click.

Build the library first (cargo build), then:
    KAYA_SELFTEST=1 python3 crates/kaya/examples/milestone0.py
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


class Occurrence(ctypes.Structure):
    _fields_ = [("kind", ctypes.c_uint16), ("widget_id", ctypes.c_uint64)]


lib.kaya_next_occurrence.argtypes = [ctypes.POINTER(Occurrence)]
lib.kaya_next_occurrence.restype = ctypes.c_bool
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
KIND_COLUMN = 1
KIND_BUTTON = 2
KIND_LABEL = 3
PROP_TEXT = 1
SOURCE_CONST = 0
SOURCE_SIGNAL = 1
VALUE_STR = 4

# Guest-allocated ids, counted from 1 per space.
SIG_TEXT = 1
W_COLUMN = 1
W_BUTTON = 2
W_LABEL = 3


def record(kind, body):
    """One packed record: {u32 size, u16 kind, u16 flags}, body, pad to 8."""
    size = 8 + len(body)
    padded = (size + 7) & ~7
    return struct.pack("<IHH", padded, kind, 0) + body + b"\0" * (padded - size)


def str_value(text):
    utf8 = text.encode()
    return struct.pack("<II", VALUE_STR, len(utf8)) + utf8


def scene_tx():
    return b"".join([
        record(TX_CREATE_SIGNAL, struct.pack("<Q", SIG_TEXT) + str_value("Clicked 0 times")),
        record(TX_CREATE_WIDGET, struct.pack("<QII", W_COLUMN, KIND_COLUMN, 0)),
        record(TX_CREATE_WIDGET, struct.pack("<QII", W_BUTTON, KIND_BUTTON, 0)),
        record(TX_SET_PROPERTY,
               struct.pack("<QII", W_BUTTON, PROP_TEXT, SOURCE_CONST) + str_value("Click me")),
        record(TX_CREATE_WIDGET, struct.pack("<QII", W_LABEL, KIND_LABEL, 0)),
        record(TX_SET_PROPERTY,
               struct.pack("<QIIQ", W_LABEL, PROP_TEXT, SOURCE_SIGNAL, SIG_TEXT)),
        record(TX_ADD_CHILD, struct.pack("<QQ", W_COLUMN, W_BUTTON)),
        record(TX_ADD_CHILD, struct.pack("<QQ", W_COLUMN, W_LABEL)),
        record(TX_MOUNT, struct.pack("<QQ", 0, W_COLUMN)),  # window 0: the default
    ])


def write_tx(text):
    return record(TX_WRITE_SIGNAL, struct.pack("<Q", SIG_TEXT) + str_value(text))


def submit(tx):
    lib.kaya_submit(tx, len(tx))


def app():
    submit(scene_tx())
    count = 0
    occurrence = Occurrence()
    while lib.kaya_next_occurrence(ctypes.byref(occurrence)):
        if occurrence.kind == BUTTON_CLICKED:
            count += 1
            noun = "time" if count == 1 else "times"
            submit(write_tx(f"Clicked {count} {noun}"))


# Not a daemon thread: after kaya_run returns, the core has signalled
# Shutdown, so the app loop ends and the join completes. Exiting while a
# daemon thread re-enters Python during interpreter finalization crashes.
app_thread = threading.Thread(target=app)
app_thread.start()
code = lib.kaya_run()  # takes over the main thread until the app exits
app_thread.join()
sys.exit(code)
