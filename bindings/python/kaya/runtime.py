"""kaya runtime for Python guests: loading, the function floor, and the
occurrence loop. Hand-written; wire.py beside it is generated.

On the desktops THE PROCESS MAIN THREAD enters run() and becomes the
core's UI thread; a Python thread is the app thread, draining
occurrences with next_occurrence() and answering with submit(). On the
HOSTED platforms (HOSTED_ENTRY below) the host app owns the UI thread
and the thread running the guest is the app thread itself.
"""

import ctypes
import os
import pathlib
import sys

from . import wire
from .wire import OCC_BUTTON_CLICKED, OCC_TEXT_CHANGED, OCC_TOGGLED, parse_occurrence
from .wire import SPEC_HASH


# The host owns the platform loop on these two, and the guest's run()
# parks as the occurrence consumer instead of entering kaya_run — Go's
# hostedEntry, spelled in Python (docs/python-mobile-plan.md §D2,
# inheriting docs/go-mobile-plan.md §D5). sys.platform "ios"/"android"
# are PEP 730/738's own values.
HOSTED_ENTRY = sys.platform in ("ios", "android")


def _find_library():
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


def _load_library():
    # The one platform-dispatched step (docs/python-mobile-plan.md §D3).
    # iOS: the core is a static archive linked into the app executable
    # with -force_load (without which dlsym answers NULL for every
    # symbol the host never calls), so the handle is the process
    # itself. Android: libkaya.so sits in the APK's jniLibs; by soname,
    # never ctypes.util.find_library, which searches /system alone.
    if sys.platform == "ios":
        return ctypes.CDLL(None)
    if sys.platform == "android":
        return ctypes.CDLL("libkaya.so")
    return ctypes.CDLL(_find_library())


_lib = _load_library()

# The stale-artifact guard: this binding was generated from one spec
# revision and the loaded core must speak the same one.
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
# A blob arriving in an OCCURRENCE is a handle into a table with no
# boundary that retires it, so it is released explicitly.
_lib.kaya_occurrence_blob.argtypes = [ctypes.c_uint64,
                                      ctypes.POINTER(ctypes.c_size_t)]
_lib.kaya_occurrence_blob.restype = ctypes.POINTER(ctypes.c_uint8)
_lib.kaya_occurrence_blob_release.argtypes = [ctypes.c_uint64]
_lib.kaya_occurrence_blob_release.restype = None
_lib.kaya_run.restype = ctypes.c_int32
# Redeeming a picked file: the handle, the mode, and out-params for the
# OS handle and seekability. Returns 0 on success (KAYA_OK).
_lib.kaya_open_picked.argtypes = [
    ctypes.c_uint64,
    ctypes.c_uint32,
    ctypes.POINTER(ctypes.c_int64),
    ctypes.POINTER(ctypes.c_uint32),
]
_lib.kaya_open_picked.restype = ctypes.c_int32
# THE ASSET TABLE (docs/assets-plan.md). No mode argument anywhere on
# this floor — assets are read-only structurally — and no descriptor.
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

# THE HOST CAPABILITY WORD (kaya.capabilities() is the sugar over it).
# CAP_AUX_WINDOWS IS THE CORE'S NUMBER WRITTEN AGAIN — ctypes has no
# header to read it out of. tools/check-sugar-surface.py holds this line
# to crates/kaya/src/scene.rs.
_lib.kaya_capabilities.restype = ctypes.c_uint64
CAP_AUX_WINDOWS = 1


def capability_bits():
    """The raw capability word. The binding's floor: guests read named
    booleans off kaya.capabilities() and never see this."""
    return _lib.kaya_capabilities()


_occ_record = ctypes.POINTER(ctypes.c_uint8)()


def _occurrence_blob(handle):
    """Redeem an occurrence blob for its bytes, and release it.

    COPY THEN RELEASE, in that order: the pointer borrows core memory
    that the release frees, and the generated decoder calls this while
    decoding so no handle ever reaches an app.
    """
    length = ctypes.c_size_t(0)
    data = _lib.kaya_occurrence_blob(handle, ctypes.byref(length))
    payload = b"" if not data else ctypes.string_at(data, length.value)
    _lib.kaya_occurrence_blob_release(handle)
    return payload


# Installed rather than imported: wire.py is generated and loads no
# library of its own.
wire.occurrence_blob = _occurrence_blob


def submit(*records):
    """Submit one transaction: the concatenation of packed records
    (tx_* results from kaya_wire), applied atomically."""
    tx = b"".join(records)
    _lib.kaya_submit(tx, len(tx))


def register_blob(data):
    """Register bulk payload bytes with the core: one copy into
    core-owned memory, returning the u64 handle the next submit consumes
    whether referenced or not. The caller's bytes may be dropped."""
    if not isinstance(data, (bytes, bytearray, memoryview)):
        raise TypeError(
            f"kaya: blob data must be bytes, not {type(data).__name__}"
        )
    data = bytes(data)
    return _lib.kaya_blob_register(data, len(data))


# What kaya_next_occurrence returns instead of a record size. WOKEN is
# deliberately smaller than any real record (a header alone is 8 bytes)
# so a consumer that has not learned about it cannot mistake it for a
# length and read past the buffer.
_OCCURRENCE_SHUTDOWN = 0
_OCCURRENCE_WOKEN = 1

# next_occurrence's answer when a background thread rang the doorbell:
# nothing was decoded. A distinct object rather than None, which already
# means shutdown.
WOKEN = object()


def wake():
    """Return the app thread from next_occurrence. Safe from any thread;
    the binding calls it from App.post."""
    _lib.kaya_wake()


def next_occurrence():
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
            # NO RECORD WAS HANDED OUT. Decoding here would re-parse the
            # PREVIOUS one — a stale re-dispatch.
            return WOKEN
        # The core owns the bytes until the next call, so they are copied
        # out here. There is no cap: an html clip is routinely kilobytes.
        kind, ident, keys, payload = parse_occurrence(
            ctypes.string_at(_occ_record, size))
        if ident is not None:
            return kind, ident, keys, payload


def run():
    """Enter the core on the calling thread (must be the process main
    thread); returns the exit code when the app ends."""
    return _lib.kaya_run()


def asset_open(name):
    """Open an asset by name; 0 is the MISS, and asset_miss_sentence says why.

    ZERO RATHER THAN A RAISE FROM THE CORE: a panic inside an `extern
    "C"` frame is an uncatchable process abort in every guest language,
    so the core answers a value and the BINDING raises.
    """
    raw = name.encode("utf-8")
    return _lib.kaya_asset_open(raw, len(raw))


def asset_bytes(handle):
    """An open asset's bytes, copied out of core memory.

    ONE COPY, AND IT IS NOT AVOIDABLE HERE: a `memoryview` over the
    borrowed pointer would outlive the release. asset_blob is the route
    that pays nothing, and it is the one a font or an icon takes.
    """
    length = ctypes.c_size_t(0)
    data = _lib.kaya_asset_bytes(handle, ctypes.byref(length))
    return b"" if not data else ctypes.string_at(data, length.value)


def asset_len(handle):
    """An open asset's byte count. 0 means the HANDLE is dead, never the
    file: the core refuses a zero-byte asset at the open."""
    return _lib.kaya_asset_len(handle)


def asset_blob(handle):
    """THE BLOB REDEMPTION: register this asset's bytes into the pending
    table and get the handle the next submit consumes. The bytes never
    enter Python — the core clones one refcount.
    """
    return _lib.kaya_asset_blob(handle)


def asset_release(handle):
    """Drop an open asset. Idempotent, so a double close and a finalizer
    after one cost nothing."""
    _lib.kaya_asset_release(handle)


# NAMED FOR THE CARRYING, not for the answering, and deliberately not
# `asset_why_not`: tools/check-diagnostics.py reads any *why_not by that
# name and holds it to the measured-branch rule, which the function that
# EARNED the name satisfies (crates/kaya/src/assets.rs). This copies
# that sentence's bytes into a str and observes nothing.
def asset_miss_sentence(name):
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


def open_picked(handle, mode):
    """Redeem a picked handle for a real file object, plus whether it
    seeks: `(file, seekable)`.

    BLOCKS, possibly for a long time — a cloud provider may download the
    file first — so call it from a thread you chose and post the result
    back (DESIGN.md, File dialogs).

    THE DESCRIPTOR BECOMES PYTHON'S: `os.fdopen` takes ownership. On
    Windows the core hands back a HANDLE rather than a CRT descriptor,
    converted here by THIS interpreter's msvcrt, which is the only one
    entitled to.
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
