"""The filedialog conformance scene, Python port — the picker's
request/result grammar and the capability it hands back (DESIGN.md,
File dialogs).

WHAT THIS PROVES, and why it goes all the way to the bytes: the design's
whole claim is that kaya hands over a CAPABILITY and never moves the
data. So the guest does not assert that a dialog closed — it opens the
handle it was given, reads the file with ORDINARY Python, and writes
what it read into a signal. `expect label#0 "1 picked bytes"` therefore
fails unless a real descriptor came back carrying the real file.

THE FILE IS THE GUEST'S OWN, written before anything is shown, so guest
and interpreter agree on a path with no runner involvement — they are
the same process. The pid keeps parallel legs from colliding, and the
scene names only the BASENAME so one script serves every lane.

THE READ RUNS OFF THE APP THREAD, which is what `open` tells every
caller to do: it blocks, and a cloud provider may download the whole
file before it returns.

The parking is a plain `threading.Event`, and the worker is a plain
daemon thread. kaya supplies no waiting primitive and should not: the
point is that a guest uses its own language's concurrency and hands
back only the result. Reading inline would contradict the API's own
documentation and would leave the property this scene uniquely proves
untested — that the CAPABILITY SURVIVES THE THREAD HOP, which is the
platform-sensitive part (a security-scoped URL on iOS, a content:// URI
plus a JNI reference on Android).

The worker PARKS between reading and posting, and only a click releases
it, so a guest that read inline is caught by `expect label#0 "reading"`
and one that did the work on the app thread wedges everything after.

See guests/rust/filedialog.rs and tools/scenes/filedialog.steps.
"""

import os
import pathlib
import sys
import tempfile
import threading

import kaya

app = kaya.App()

# Both halves compute this identically; see the module note. The
# desktops' answer is the temp directory — the phones need somewhere
# their picker can actually browse, which is why the Rust guest carries
# per-platform arms. Python runs on the three desktops only.
# `tempfile.gettempdir()` and NOT `TMPDIR`: the environment variable is
# a POSIX spelling, and on Windows there is none — reading it fell back
# to a literal "/tmp", so the guest wrote its files to the root of the
# current drive while the interpreter aimed the picker at the real
# temp directory. The picker then opened somewhere with no scene files
# in it at all, which is precisely the silent failure this scene's
# comments warn about. Each half must compute the directory THE WAY ITS
# OWN LANGUAGE DOES, and this is Python's way.
picked_dir = pathlib.Path(tempfile.gettempdir()) / f"kaya-picked-{os.getpid()}"
picked_dir.mkdir(parents=True, exist_ok=True)
# THE DECOY IS LOAD-BEARING: with one file in the directory, pressing
# Open with nothing selected returns that file, so `file_choose
# picked.txt` would pass on a backend that ignored the name entirely.
# Measured on GTK. "decoy" sorts before "picked", so a backend that
# skips selection gets the WRONG file, and its five bytes fail the byte
# assertion as well as the name.
(picked_dir / "picked.txt").write_text("picked bytes")
(picked_dir / "decoy.txt").write_text("decoy")

# The release gate: the app thread sends, the worker receives. A
# handler that blocked handing this over would fail the very claim being
# tested, so the send must not wait for the receiver.
released = threading.Event()


def picked(files):
    if not files:
        # The empty list IS cancel. Nothing to read, so no worker and
        # no release.
        status.set("cancelled")
        return

    def worker():
        # THE CLAIM, and it is made HERE rather than in the handler on
        # purpose: the handle crossed a thread boundary, and it is
        # redeemed and read with Python's own file API on the thread
        # that received it. kaya is not in this data path, and `open`
        # is documented to block.
        count = len(files)
        try:
            handle, seekable = files[0].open(kaya.wire.FILE_MODE_READ)
            with handle as f:
                text = f.read().decode()
        except OSError as e:
            text = f"open failed: {e}"
        # Parks holding the result, standing in for the tail of a slow
        # transfer. Were this work running on the app thread, the
        # release click could never be processed and the whole scene
        # would deadlock — the point, and much stronger than reading
        # back a different value.
        released.wait()
        app.post(lambda: status.set(f"{count} {text}"))

    threading.Thread(target=worker, name="filedialog-reader",
                     daemon=True).start()
    # The handler RETURNED without reading. A guest that did the work
    # eagerly arrives at the next step already showing the final text,
    # and the scene says so.
    status.set("reading")


def ask():
    # ADVISORY on every platform: a default view, never a guarantee, so
    # a guest still validates what it got — which is what the read does.
    kaya.pick_files(filters=[("Text", "txt")], on_result=picked)


def ask_one():
    kaya.pick_file(filters=[("Text", "txt")], on_result=picked)


with app.window(title="filedialog"):
    status = kaya.signal("no file")
    with kaya.column():
        kaya.label(bind=status).a11y_id("status")  # label#0
        kaya.button("open", on_click=ask)  # button#0
        kaya.button("open one", on_click=ask_one)  # button#1
        kaya.button("release", on_click=released.set)  # button#2

sys.exit(app.run())
