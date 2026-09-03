"""The save round trip (tools/scenes/save.steps). EVERY STATUS IS A READ-BACK
OFF THE DISK, through the HANDLE, and no name carries an extension."""

import os
import pathlib
import sys
import tempfile
import threading

import kaya

app = kaya.App()

# Both halves compute this identically. `tempfile.gettempdir()` and NEVER
# `TMPDIR` — docs/traps.md.
save_dir = pathlib.Path(tempfile.gettempdir()) / f"kaya-save-{os.getpid()}"
save_dir.mkdir(parents=True, exist_ok=True)
# The decoy the picker needs (guests/python/filedialog.py says why):
# "decoy" MUST sort before "draft".
(save_dir / "draft").write_text("first draft")
(save_dir / "decoy").write_text("decoy")

# HANDLES and never paths: the phones have no re-openable path.
source = None
destination = None


def read_back(picked):
    """Read a handle back through kaya, with Python's own file API."""
    try:
        handle, _seekable = picked.open(kaya.wire.FILE_MODE_READ)
    except OSError as e:
        return f"open failed: {e}"
    try:
        with handle as f:
            return f.read().decode()
    except OSError as e:
        return f"read failed: {e}"


def write_back(picked, text):
    """Write `text` through a handle and report what the file says
    afterwards. FILE_MODE_WRITE truncates, on a picked file and on a
    save destination alike — the destination only adds the create."""
    try:
        handle, _seekable = picked.open(kaya.wire.FILE_MODE_WRITE)
    except OSError as e:
        # Without the create a save destination cannot be opened
        # (docs/save-plan.md D1).
        return f"save failed: {e}"
    try:
        # Closed BEFORE the reopen, so the bytes read back are the file's.
        with handle as f:
            f.write(text.encode())
    except OSError as e:
        return f"write failed: {e}"
    return read_back(picked)


def work(job):
    """Run one file operation on a thread of the guest's own and post the
    answer back."""
    def worker():
        text = job()
        app.post(lambda: status.set(text))

    threading.Thread(target=worker, name="save-worker", daemon=True).start()


def picked(files):
    global source
    if not files:
        status.set("open cancelled")
        return
    file = files[0]
    source = file
    work(lambda: f"opened {read_back(file)}")


def saved(file):
    global destination
    if file is None:
        status.set("save cancelled")
        return
    destination = file
    work(lambda: f"saved {write_back(file, 'third draft')}")


def open_file():
    kaya.pick_file(on_result=picked)


def save_back():
    # No dialog: the chosen handle is writable. A missing one gets its OWN
    # sentence, never a crash (docs/deferred.md, save-jvm WATCH).
    file = source
    if file is None:
        status.set("nothing open to save")
        return
    work(lambda: f"saved {write_back(file, 'second draft')}")


def save_as():
    # The name the dialog OPENS with. NO FILTER either: with types set,
    # NSSavePanel appends an extension (docs/deferred.md).
    kaya.save_file("copy", on_result=saved)


def reopen():
    # A save through the wrong handle fails only here.
    first, second = source, destination
    if first is None or second is None:
        status.set("nothing to reopen")
        return
    work(lambda: f"reopened {read_back(first)} {read_back(second)}")


with app.window(title="save"):
    status = kaya.signal("no file")
    with kaya.column():
        kaya.label(bind=status).a11y_id("status")  # label#0
        kaya.button("open", on_click=open_file)  # button#0
        kaya.button("save", on_click=save_back)  # button#1
        kaya.button("save as", on_click=save_as)  # button#2
        kaya.button("reopen", on_click=reopen)  # button#3

sys.exit(app.run())
