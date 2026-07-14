"""Milestone 0 from the other side of the C ABI (function floor).

The host language's main thread enters kaya_run() and becomes the core's
UI thread. A Python thread is the app thread: it drains occurrences and
sends commands. Same round trip as the Rust example, no Rust in the app
logic.

Build the library first (cargo build), then:
    KAYA_SELFTEST=1 python3 crates/kaya/examples/milestone0.py
On Windows, ensure the directory holding kaya.dll and the bootstrap DLL
is on PATH (or run from that directory).
"""

import ctypes
import os
import pathlib
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
lib.kaya_set_text.argtypes = [ctypes.c_uint64, ctypes.c_char_p, ctypes.c_size_t]
lib.kaya_set_text.restype = None
lib.kaya_run.restype = ctypes.c_int32

BUTTON_CLICKED = 1
LABEL = 2


def app():
    count = 0
    occurrence = Occurrence()
    while lib.kaya_next_occurrence(ctypes.byref(occurrence)):
        if occurrence.kind == BUTTON_CLICKED:
            count += 1
            noun = "time" if count == 1 else "times"
            text = f"Clicked {count} {noun}".encode()
            lib.kaya_set_text(LABEL, text, len(text))


# Not a daemon thread: after kaya_run returns, the core has signalled
# Shutdown, so the app loop ends and the join completes. Exiting while a
# daemon thread re-enters Python during interpreter finalization crashes.
app_thread = threading.Thread(target=app)
app_thread.start()
code = lib.kaya_run()  # takes over the main thread until the app exits
app_thread.join()
sys.exit(code)
