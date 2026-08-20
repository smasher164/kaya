"""The save conformance scene, Python port — the ROUND TRIP an editor
actually walks (docs/save-plan.md D5): open a file, edit it, save it
back, save it AS somewhere new, then reopen both and prove the bytes
are where they belong. The four claims it drives are docs/save-plan.md
D1's numbered list.

EVERY STATUS IS A READ-BACK OFF THE DISK, never what the guest hoped it
wrote: a write that returned success and landed nowhere is exactly the
failure "save" has, and only reopening sees it.

THE FILE IS READ THROUGH THE HANDLE, NEVER THROUGH `local_path` — that
name is empty on both phones, so a port that reached for it would pass
on the desktops and be unportable by construction.

THE WORK RUNS OFF THE APP THREAD, which is what `open` documents.

NO EXTENSIONS ON THE NAMES: a hidden-extension Finder preference would
make `expect_save_dialog` read the stem on one machine and the whole
name on another (docs/deferred.md).

See guests/rust/save.rs and tools/scenes/save.steps.
"""

import os
import pathlib
import sys
import tempfile
import threading

import kaya

app = kaya.App()

# Both halves compute this identically, each in its own language's way.
# `tempfile.gettempdir()` and NEVER `TMPDIR` — see docs/traps.md. Python
# runs on the three desktops only, so there are no phone arms here.
save_dir = pathlib.Path(tempfile.gettempdir()) / f"kaya-save-{os.getpid()}"
save_dir.mkdir(parents=True, exist_ok=True)
# The file the scene opens, plus the decoy the picker needs (see
# guests/python/filedialog.py). "decoy" MUST sort before "draft".
(save_dir / "draft").write_text("first draft")
(save_dir / "decoy").write_text("decoy")

# Held as handles, never as paths: the phones have no re-openable path,
# and the desktops must not be allowed to pass with one.
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
        # The failure docs/save-plan.md D1 exists to prevent reaches the
        # label verbatim.
        return f"save failed: {e}"
    try:
        # Closed by the `with` BEFORE the reopen, so the bytes read back
        # are the file's and not a buffer's.
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
    # Save-back needs no dialog — the user already chose this file, and
    # the handle they chose it with is writable. A missing handle is an
    # open that never landed (cancelled, or the dialog swallowed under
    # load) — its OWN sentence, never a crash: a crashed guest takes
    # the process and masks the real failure (docs/deferred.md,
    # save-jvm WATCH).
    file = source
    if file is None:
        status.set("nothing open to save")
        return
    work(lambda: f"saved {write_back(file, 'second draft')}")


def save_as():
    # The suggested name the dialog OPENS with; the harness types over
    # it. NO FILTER here either, and that one matters: with allowed
    # content types set, NSSavePanel appends the first allowed extension
    # to an extension-less name (docs/deferred.md).
    kaya.save_file("copy", on_result=saved)


def reopen():
    # BOTH, in order: a save that went to the wrong handle passes every
    # earlier step and fails here. The missing-handle guard, same
    # reason as save_back's.
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
