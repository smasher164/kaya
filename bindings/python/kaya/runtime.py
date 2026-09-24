"""kaya runtime for Python guests: loading, the function floor, and the
occurrence loop. Hand-written; wire.py beside it is generated.
"""

from __future__ import annotations

import ctypes
import os
import pathlib
import sys
from collections.abc import Callable, Sequence
from typing import IO, Any

from . import wire
from .wire import OCC_BUTTON_CLICKED, OCC_TEXT_CHANGED, OCC_TOGGLED, parse_occurrence
from .wire import SPEC_HASH


# The host owns the platform loop on these two, so run() parks as the
# occurrence consumer instead of entering kaya_run
# (docs/python-mobile-plan.md §D2). The two strings are sys.platform's
# own values (PEP 730/738).
HOSTED_ENTRY = sys.platform in ("ios", "android")


def _find_library() -> str:
    if lib := os.environ.get("KAYA_LIB"):
        return lib
    name = {"darwin": "libkaya.dylib", "win32": "kaya.dll"}.get(
        sys.platform, "libkaya.so"
    )
    here = pathlib.Path(__file__).resolve().parent
    for base in [here, *here.parents]:
        for candidate in [base / name, base / "target" / "debug" / name]:
            if candidate.exists():
                return str(candidate)
    raise FileNotFoundError(f"{name} not found; build with cargo or set KAYA_LIB")


def _load_library() -> ctypes.CDLL:
    # The one platform-dispatched step (docs/python-mobile-plan.md §D3):
    # iOS needs -force_load on libkaya.a or dlsym answers NULL, and
    # Android must load by soname, never ctypes.util.find_library.
    if sys.platform == "ios":
        return ctypes.CDLL(None)
    if sys.platform == "android":
        return ctypes.CDLL("libkaya.so")
    return ctypes.CDLL(_find_library())


_lib = _load_library()

_lib.kaya_spec_hash.restype = ctypes.c_uint64
if _lib.kaya_spec_hash() != SPEC_HASH:
    raise RuntimeError(
        f"kaya: library speaks spec {_lib.kaya_spec_hash():#018x}, this binding was "
        f"generated from {SPEC_HASH:#018x} — rebuild the library or regenerate bindings"
    )
_lib.kaya_next_occurrence.argtypes = [ctypes.POINTER(ctypes.POINTER(ctypes.c_uint8))]
_lib.kaya_next_occurrence.restype = ctypes.c_size_t
_lib.kaya_submit.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
_lib.kaya_submit.restype = None
_lib.kaya_blob_register.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
_lib.kaya_blob_register.restype = ctypes.c_uint64
_lib.kaya_occurrence_blob.argtypes = [ctypes.c_uint64,
                                      ctypes.POINTER(ctypes.c_size_t)]
_lib.kaya_occurrence_blob.restype = ctypes.POINTER(ctypes.c_uint8)
_lib.kaya_occurrence_blob_release.argtypes = [ctypes.c_uint64]
_lib.kaya_occurrence_blob_release.restype = None
_lib.kaya_run.restype = ctypes.c_int32
_lib.kaya_open_picked.argtypes = [
    ctypes.c_uint64,
    ctypes.c_uint32,
    ctypes.POINTER(ctypes.c_int64),
    ctypes.POINTER(ctypes.c_uint32),
]
_lib.kaya_open_picked.restype = ctypes.c_int32
# The asset table (docs/assets-plan.md).
_lib.kaya_asset_open.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
_lib.kaya_asset_open.restype = ctypes.c_uint64
_lib.kaya_asset_bytes.argtypes = [ctypes.c_uint64,
                                  ctypes.POINTER(ctypes.c_size_t)]
_lib.kaya_asset_bytes.restype = ctypes.POINTER(ctypes.c_uint8)
_lib.kaya_asset_len.argtypes = [ctypes.c_uint64]
_lib.kaya_asset_len.restype = ctypes.c_size_t
_lib.kaya_asset_blob.argtypes = [ctypes.c_uint64]
_lib.kaya_asset_blob.restype = ctypes.c_uint64
_lib.kaya_asset_release.argtypes = [ctypes.c_uint64]
_lib.kaya_asset_release.restype = None
_lib.kaya_asset_why_not.argtypes = [ctypes.c_char_p, ctypes.c_size_t,
                                    ctypes.c_char_p, ctypes.c_size_t]
_lib.kaya_asset_why_not.restype = ctypes.c_size_t

# The app's own places (docs/tasks-s4-plan.md §4): the data directory
# and the typed preferences store.
_lib.kaya_app_data_dir.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
_lib.kaya_app_data_dir.restype = ctypes.c_size_t
_lib.kaya_pref_get_string.argtypes = [
    ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_size_t)]
_lib.kaya_pref_get_string.restype = ctypes.c_int
_lib.kaya_pref_get_i64.argtypes = [ctypes.c_char_p, ctypes.c_size_t,
                                   ctypes.POINTER(ctypes.c_int64)]
_lib.kaya_pref_get_i64.restype = ctypes.c_int
_lib.kaya_pref_get_f64.argtypes = [ctypes.c_char_p, ctypes.c_size_t,
                                   ctypes.POINTER(ctypes.c_double)]
_lib.kaya_pref_get_f64.restype = ctypes.c_int
_lib.kaya_pref_get_bool.argtypes = [ctypes.c_char_p, ctypes.c_size_t,
                                    ctypes.POINTER(ctypes.c_uint8)]
_lib.kaya_pref_get_bool.restype = ctypes.c_int
_lib.kaya_pref_set_string.argtypes = [ctypes.c_char_p, ctypes.c_size_t,
                                      ctypes.c_char_p, ctypes.c_size_t]
_lib.kaya_pref_set_string.restype = None
_lib.kaya_pref_set_i64.argtypes = [ctypes.c_char_p, ctypes.c_size_t,
                                   ctypes.c_int64]
_lib.kaya_pref_set_i64.restype = None
_lib.kaya_pref_set_f64.argtypes = [ctypes.c_char_p, ctypes.c_size_t,
                                   ctypes.c_double]
_lib.kaya_pref_set_f64.restype = None
_lib.kaya_pref_set_bool.argtypes = [ctypes.c_char_p, ctypes.c_size_t,
                                    ctypes.c_uint8]
_lib.kaya_pref_set_bool.restype = None
_lib.kaya_pref_remove.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
_lib.kaya_pref_remove.restype = None

# The formatter door and the catalog (docs/compliance-plan.md §3; the C
# API block in crates/kaya/src/capi.rs).
_lib.kaya_fmt_date.argtypes = [ctypes.c_int64, ctypes.c_int64, ctypes.c_char_p,
                               ctypes.c_size_t]
_lib.kaya_fmt_date.restype = ctypes.c_size_t
_lib.kaya_fmt_date_weekday.argtypes = [ctypes.c_int64, ctypes.c_char_p,
                                       ctypes.c_size_t]
_lib.kaya_fmt_date_weekday.restype = ctypes.c_size_t
_lib.kaya_fmt_time.argtypes = [ctypes.c_int64, ctypes.c_int64, ctypes.c_char_p,
                               ctypes.c_size_t]
_lib.kaya_fmt_time.restype = ctypes.c_size_t
_lib.kaya_fmt_date_time.argtypes = [ctypes.c_int64, ctypes.c_int64,
                                    ctypes.c_int64, ctypes.c_char_p,
                                    ctypes.c_size_t]
_lib.kaya_fmt_date_time.restype = ctypes.c_size_t


class KayaNumberOptions(ctypes.Structure):
    _fields_ = [("min_fraction_digits", ctypes.c_int32),
                ("max_fraction_digits", ctypes.c_int32),
                ("grouping", ctypes.c_bool)]


_lib.kaya_fmt_number.argtypes = [ctypes.c_double,
                                 ctypes.POINTER(KayaNumberOptions),
                                 ctypes.c_char_p, ctypes.c_size_t]
_lib.kaya_fmt_number.restype = ctypes.c_size_t
_lib.kaya_fmt_percent.argtypes = [ctypes.c_double,
                                  ctypes.POINTER(KayaNumberOptions),
                                  ctypes.c_char_p, ctypes.c_size_t]
_lib.kaya_fmt_percent.restype = ctypes.c_size_t
_lib.kaya_fmt_currency.argtypes = [ctypes.c_double, ctypes.c_char_p,
                                   ctypes.c_char_p, ctypes.c_size_t]
_lib.kaya_fmt_currency.restype = ctypes.c_size_t
_lib.kaya_locale.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
_lib.kaya_locale.restype = ctypes.c_size_t
_lib.kaya_direction.restype = ctypes.c_uint32
_lib.kaya_text_scale.restype = ctypes.c_double
_lib.kaya_catalog.argtypes = [ctypes.c_char_p]
_lib.kaya_catalog.restype = None


class KayaTrArg(ctypes.Structure):
    _fields_ = [("name", ctypes.c_char_p), ("tag", ctypes.c_uint32),
                ("i", ctypes.c_int64), ("f", ctypes.c_double),
                ("s", ctypes.c_char_p)]


TR_INT = 0
TR_FLOAT = 1
TR_STR = 2
TR_DATE = 3
TR_TIME = 4

_lib.kaya_tr.argtypes = [ctypes.c_char_p, ctypes.POINTER(KayaTrArg),
                         ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t]
_lib.kaya_tr.restype = ctypes.c_size_t

# CAP_AUX_WINDOWS is the core's number written again — ctypes has no
# header to read it out of; tools/check-sugar-surface.py holds it to
# crates/kaya/src/scene.rs.
_lib.kaya_capabilities.restype = ctypes.c_uint64
CAP_AUX_WINDOWS = 1
CAP_NOTIFICATIONS = 2


def capability_bits() -> int:
    """The raw capability word."""
    return _lib.kaya_capabilities()


_occ_record = ctypes.POINTER(ctypes.c_uint8)()


def _occurrence_blob(handle: int) -> bytes:
    """Redeem an occurrence blob for its bytes, and release it.

    COPY THEN RELEASE, in that order: the pointer borrows core memory
    that the release frees.
    """
    length = ctypes.c_size_t(0)
    data = _lib.kaya_occurrence_blob(handle, ctypes.byref(length))
    payload = b"" if not data else ctypes.string_at(data, length.value)
    _lib.kaya_occurrence_blob_release(handle)
    return payload


# Installed rather than imported: wire.py is generated and loads no
# library of its own.
wire.occurrence_blob = _occurrence_blob


def submit(*records: bytes) -> None:
    """Submit one transaction: the concatenation of packed records,
    applied atomically."""
    tx = b"".join(records)
    _lib.kaya_submit(tx, len(tx))


def register_blob(data: bytes | bytearray | memoryview) -> int:
    """Register bulk payload bytes with the core, returning the handle
    the next submit consumes whether referenced or not."""
    if not isinstance(data, (bytes, bytearray, memoryview)):
        raise TypeError(
            f"kaya: blob data must be bytes, not {type(data).__name__}"
        )
    data = bytes(data)
    return _lib.kaya_blob_register(data, len(data))


# Returned instead of a record size. WOKEN is deliberately smaller than
# any real record (a header alone is 8 bytes), so a consumer that has
# not learned about it cannot mistake it for a length and read past the
# buffer.
_OCCURRENCE_SHUTDOWN = 0
_OCCURRENCE_WOKEN = 1

# A distinct object rather than None, which already means shutdown. Typed
# `Any` because it rides next_occurrence's own return slot: the consumer
# tests it BY IDENTITY before unpacking the tuple (App._dispatch_loop), and
# a sentinel is the one place a dynamic type is the honest one.
WOKEN: Any = object()


def wake() -> None:
    """Return the app thread from next_occurrence. Safe from any thread."""
    _lib.kaya_wake()


def next_occurrence() -> tuple[int, Any, list[Any], Any] | None:
    """Block for the next occurrence; None when the core has shut down,
    WOKEN when a background thread has queued work for the app thread.

    Returns (kind, id, keys, payload): keys is [] when id is a widget
    id, else id is a template node id and keys is the stamped copy's
    key path, outermost first. payload is the entry's new text for
    OCC_TEXT_CHANGED, the checkbox's new state for OCC_TOGGLED, None
    for clicks.
    """
    while True:
        size = _lib.kaya_next_occurrence(ctypes.byref(_occ_record))
        if size == _OCCURRENCE_SHUTDOWN:
            return None
        if size == _OCCURRENCE_WOKEN:
            # NO RECORD WAS HANDED OUT: decoding here would re-parse the
            # PREVIOUS one.
            return WOKEN
        # The core owns the bytes until the next call, so copy them out.
        kind, ident, keys, payload = parse_occurrence(
            ctypes.string_at(_occ_record, size))
        if ident is not None:
            return kind, ident, keys, payload


def run() -> int:
    """Enter the core on the calling thread (must be the process main
    thread); returns the exit code when the app ends."""
    return _lib.kaya_run()


def asset_open(name: str) -> int:
    """Open an asset by name; 0 is the MISS, and asset_miss_sentence says why."""
    raw = name.encode("utf-8")
    return _lib.kaya_asset_open(raw, len(raw))


def asset_bytes(handle: int) -> bytes:
    """An open asset's bytes, copied out of core memory.

    THE COPY IS NOT AVOIDABLE: a `memoryview` over the borrowed pointer
    would outlive the release. asset_blob is the route that pays nothing.
    """
    length = ctypes.c_size_t(0)
    data = _lib.kaya_asset_bytes(handle, ctypes.byref(length))
    return b"" if not data else ctypes.string_at(data, length.value)


def asset_len(handle: int) -> int:
    """An open asset's byte count. 0 means the HANDLE is dead, never the
    file: the core refuses a zero-byte asset at the open."""
    return _lib.kaya_asset_len(handle)


def asset_blob(handle: int) -> int:
    """Register this asset's bytes into the pending table and get the
    handle the next submit consumes; the bytes never enter Python.
    """
    return _lib.kaya_asset_blob(handle)


def asset_release(handle: int) -> None:
    """Drop an open asset. Idempotent, so a double close and a finalizer
    after one cost nothing."""
    _lib.kaya_asset_release(handle)


# Deliberately not named `asset_why_not`: tools/check-diagnostics.py
# reads any *why_not by that name and holds it to the measured-branch
# rule, which crates/kaya/src/assets.rs satisfies. This only copies that
# sentence's bytes.
def asset_miss_sentence(name: str) -> str:
    """The core's sentence for why `asset(name)` would fail — empty when
    it would succeed.

    ASKED TWICE ON PURPOSE: the first call learns the length, the second
    fills a buffer of exactly that size. A fixed buffer would truncate
    the END, which is where the census of what IS there lives.
    """
    raw = name.encode("utf-8")
    needed = _lib.kaya_asset_why_not(raw, len(raw), None, 0)
    if needed == 0:
        return ""
    out = ctypes.create_string_buffer(needed)
    written = _lib.kaya_asset_why_not(raw, len(raw), out, needed)
    return out.raw[:min(written, needed)].decode("utf-8", "replace")


def open_picked(handle: int, mode: int) -> tuple[IO[bytes], bool]:
    """Redeem a picked handle for a real file object, plus whether it
    seeks: `(file, seekable)`.

    BLOCKS, possibly for a long time, so call it from a thread you chose
    and post the result back (DESIGN.md, File dialogs).

    On Windows the core hands back a HANDLE rather than a CRT
    descriptor, converted here by THIS interpreter's msvcrt, which is
    the only one entitled to.
    """
    raw = ctypes.c_int64(0)
    seekable = ctypes.c_uint32(0)
    rc = _lib.kaya_open_picked(
        ctypes.c_uint64(handle), ctypes.c_uint32(mode),
        ctypes.byref(raw), ctypes.byref(seekable))
    if rc != 0:
        raise OSError(f"kaya: opening the picked file failed (code {rc})")
    if sys.platform == "win32":
        import msvcrt
        flags = os.O_RDONLY if mode == 0 else os.O_RDWR
        fd = msvcrt.open_osfhandle(raw.value, flags)
    else:
        fd = raw.value
    modes = {0: "rb", 1: "wb", 2: "r+b"}
    return os.fdopen(fd, modes[mode]), bool(seekable.value)


def app_data_dir() -> str | None:
    """The app's own writable directory, or None before one exists
    (docs/tasks-s4-plan.md §4). SIZED, THEN READ, asset_miss_sentence's
    two-call shape."""
    needed = _lib.kaya_app_data_dir(None, 0)
    if needed == 0:
        return None
    out = ctypes.create_string_buffer(needed)
    written = _lib.kaya_app_data_dir(out, needed)
    return out.raw[:min(written, needed)].decode("utf-8", "replace")


def _key(key: str) -> tuple[bytes, int]:
    raw = key.encode("utf-8")
    return raw, len(raw)


def _filled(verb: str, ask: Callable[[Any, int], int]) -> str:
    """The fill shape (app_data_dir's): size, then read. A 0 answer is the
    core's FAULT (its sentence is already on stderr), never an empty
    string handed on."""
    needed = ask(None, 0)
    if needed == 0:
        raise RuntimeError(f"kaya: {verb} refused its input (the core's sentence is above)")
    out = ctypes.create_string_buffer(needed)
    written = ask(out, needed)
    return out.raw[:min(written, needed)].decode("utf-8", "replace")


def fmt_date(packed: int, length: int) -> str:
    return _filled("kaya_fmt_date", lambda o, c: _lib.kaya_fmt_date(packed, length, o, c))


def fmt_date_weekday(packed: int) -> str:
    return _filled("kaya_fmt_date_weekday",
                   lambda o, c: _lib.kaya_fmt_date_weekday(packed, o, c))


def fmt_time(packed: int, length: int) -> str:
    return _filled("kaya_fmt_time", lambda o, c: _lib.kaya_fmt_time(packed, length, o, c))


def fmt_date_time(date: int, time: int, length: int) -> str:
    return _filled("kaya_fmt_date_time",
                   lambda o, c: _lib.kaya_fmt_date_time(date, time, length, o, c))


def _number_options(min_digits: int | None, max_digits: int | None,
                    grouping: bool) -> KayaNumberOptions:
    return KayaNumberOptions(-1 if min_digits is None else min_digits,
                             -1 if max_digits is None else max_digits, grouping)


def fmt_number(value: float, min_digits: int | None, max_digits: int | None,
               grouping: bool) -> str:
    options = _number_options(min_digits, max_digits, grouping)
    return _filled("kaya_fmt_number",
                   lambda o, c: _lib.kaya_fmt_number(value, ctypes.byref(options), o, c))


def fmt_percent(value: float, min_digits: int | None, max_digits: int | None,
                grouping: bool) -> str:
    options = _number_options(min_digits, max_digits, grouping)
    return _filled("kaya_fmt_percent",
                   lambda o, c: _lib.kaya_fmt_percent(value, ctypes.byref(options), o, c))


def fmt_currency(value: float, code: str) -> str:
    raw = code.encode("utf-8")
    return _filled("kaya_fmt_currency",
                   lambda o, c: _lib.kaya_fmt_currency(value, raw, o, c))


def locale_line() -> str:
    """kaya_locale's one line: tag, hour cycle, first weekday, calendar,
    numbering, space-separated."""
    return _filled("kaya_locale", lambda o, c: _lib.kaya_locale(o, c))


def direction() -> int:
    """0 left-to-right, 1 right-to-left."""
    return _lib.kaya_direction()


def text_scale() -> float:
    return _lib.kaya_text_scale()


def catalog(app: str) -> None:
    _lib.kaya_catalog(app.encode("utf-8"))


def tr(key: str, args: Sequence[tuple[str, int, int, float, str]]) -> str:
    """`args` are (name, tag, i, f, s) records in the C API's own shape."""
    packed = (KayaTrArg * max(len(args), 1))()
    keep: list[bytes] = []
    for at, (name, tag, i, f, s) in enumerate(args):
        raw_name = name.encode("utf-8")
        raw_s = s.encode("utf-8")
        keep.extend((raw_name, raw_s))
        packed[at] = KayaTrArg(raw_name, tag, i, f, raw_s)
    raw_key = key.encode("utf-8")
    return _filled("kaya_tr", lambda o, c: _lib.kaya_tr(raw_key, packed, len(args), o, c))


def pref_get_string(key: str) -> str | None:
    """The stored string, or None when the key is absent or holds
    another type."""
    raw, n = _key(key)
    length = ctypes.c_size_t(0)
    if not _lib.kaya_pref_get_string(raw, n, None, 0, ctypes.byref(length)):
        return None
    if length.value == 0:
        return ""
    out = ctypes.create_string_buffer(length.value)
    if not _lib.kaya_pref_get_string(raw, n, out, length.value,
                                     ctypes.byref(length)):
        return None
    return out.raw[:length.value].decode("utf-8", "replace")


def pref_get_i64(key: str) -> int | None:
    raw, n = _key(key)
    out = ctypes.c_int64(0)
    if not _lib.kaya_pref_get_i64(raw, n, ctypes.byref(out)):
        return None
    return out.value


def pref_get_f64(key: str) -> float | None:
    raw, n = _key(key)
    out = ctypes.c_double(0.0)
    if not _lib.kaya_pref_get_f64(raw, n, ctypes.byref(out)):
        return None
    return out.value


def pref_get_bool(key: str) -> bool | None:
    raw, n = _key(key)
    out = ctypes.c_uint8(0)
    if not _lib.kaya_pref_get_bool(raw, n, ctypes.byref(out)):
        return None
    return out.value != 0


def pref_set_string(key: str, value: str) -> None:
    raw, n = _key(key)
    packed = value.encode("utf-8")
    _lib.kaya_pref_set_string(raw, n, packed, len(packed))


def pref_set_i64(key: str, value: int) -> None:
    raw, n = _key(key)
    _lib.kaya_pref_set_i64(raw, n, value)


def pref_set_f64(key: str, value: float) -> None:
    raw, n = _key(key)
    _lib.kaya_pref_set_f64(raw, n, value)


def pref_set_bool(key: str, value: bool) -> None:
    raw, n = _key(key)
    _lib.kaya_pref_set_bool(raw, n, 1 if value else 0)


def pref_remove(key: str) -> None:
    raw, n = _key(key)
    _lib.kaya_pref_remove(raw, n)
