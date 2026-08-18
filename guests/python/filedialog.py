"""The filedialog conformance scene, Python port — the picker's
request/result grammar and the capability it hands back (DESIGN.md,
File dialogs).

The guest does not assert that a dialog closed: it opens the handle it
was given, reads the file with ORDINARY Python, and writes what it read
into a signal, so `expect label#0 "1 picked bytes"` fails unless a real
descriptor came back carrying the real file.

THE FILE IS THE GUEST'S OWN, written before anything is shown, so guest
and interpreter agree on a path with no runner involvement. The pid
keeps parallel legs from colliding, and the scene names only the
BASENAME so one script serves every lane.

THE READ RUNS OFF THE APP THREAD, which is what `open` documents: it
blocks, and a cloud provider may download the whole file first. The
property this buys is that the CAPABILITY SURVIVES THE THREAD HOP (a
security-scoped URL on iOS, a content:// URI plus a JNI reference on
Android). The worker PARKS between reading and posting and only a click
releases it, so a guest that read inline is caught by
`expect label#0 "reading"` and one that worked on the app thread wedges
everything after.

See guests/rust/filedialog.rs and tools/scenes/filedialog.steps.
"""

import os
import pathlib
import sys
import tempfile
import threading

import kaya

app = kaya.App()

# Both halves compute this identically, each in its own language's way.
# `tempfile.gettempdir()` and NEVER `TMPDIR` — see docs/traps.md, the
# POSIX-spelling trap that aimed the guest at the root of the current
# drive on Windows while the picker opened on the real temp directory.
# Python runs on the three desktops only, so there are no phone arms.
picked_dir = pathlib.Path(tempfile.gettempdir()) / f"kaya-picked-{os.getpid()}"
picked_dir.mkdir(parents=True, exist_ok=True)
# The decoy MUST sort before picked.txt: pressing Open with nothing
# selected still returns a file (docs/traps.md), so a backend that skips
# selection has to get the WRONG one.
(picked_dir / "picked.txt").write_text("picked bytes")
(picked_dir / "decoy.txt").write_text("decoy")

# The release gate: the app thread sends, the worker receives. The send
# must NOT wait for the receiver.
released = threading.Event()


def picked(files):
    if not files:
        # The empty list IS cancel.
        status.set("cancelled")
        return

    def worker():
        # Redeemed and read on the thread that RECEIVED the handle, which
        # is the claim: kaya is not in this data path.
        count = len(files)
        try:
            handle, seekable = files[0].open(kaya.wire.FILE_MODE_READ)
            with handle as f:
                text = f.read().decode()
        except OSError as e:
            text = f"open failed: {e}"
        # Parks holding the result: work on the app thread would leave
        # the release click unprocessed and deadlock the scene.
        released.wait()
        app.post(lambda: status.set(f"{count} {text}"))

    threading.Thread(target=worker, name="filedialog-reader",
                     daemon=True).start()
    # The handler RETURNED without reading; the scene asserts this text.
    status.set("reading")


def ask():
    # Filters are ADVISORY on every platform — a default view, never a
    # guarantee — so the guest still validates what it got.
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
