"""The save conformance scene, Python port — the ROUND TRIP an editor
actually walks (docs/save-plan.md D5): open a file, edit it, save it
back, save it AS somewhere new, then reopen both and prove the bytes
are where they belong.

WHAT THIS PROVES, and none of it is about a dialog closing:

1. **Save-back works.** Writing through the handle the OPEN picker
   handed over — the thing DESIGN.md has claimed since the picker
   landed, and that no scene, leg or test drove until this one.
2. **A save destination is openable at all.** A save dialog on the
   desktops answers with a name for a file NOBODY HAS MADE (measured on
   macOS: `exists=false` after a clean Save), so opening it would fail
   with "No such file or directory" for a file the user just named. The
   core's save destination creates; D1 is the decision and this is
   where it shows.
3. **The two files stay different.** The last step reopens BOTH handles
   and reports both contents, so a save-as that quietly wrote back into
   the ORIGINAL — the plausible bug, since the guest holds two handles
   that look alike — fails here and nowhere else.
4. **Cancel is nothing, and the dialog id retires.** The scene shows a
   save dialog, cancels it, and shows another. A cancel that leaked the
   live slot would fail on the second show.

EVERY STATUS IS A READ-BACK OFF THE DISK. The guest never reports what
it hoped it wrote: each string is the file reopened through the handle
kaya gave it and read with ORDINARY Python. A write that returned
success and landed nowhere is exactly the failure "save" has, and only
reopening can see it. The strings are byte-frozen and compared
identically on every lane, so "saved second draft" carries the CONTENT
rather than a verdict.

THE FILE IS READ THROUGH THE HANDLE, NEVER THROUGH `local_path` — that
name is empty on both phones, and a port that reached for it would pass
on the desktops and be unportable by construction.

THE WORK RUNS OFF THE APP THREAD, which is what `open` tells every
caller to do: it blocks, and a cloud provider may download the whole
file first. A guest that did this inline would contradict its own API
documentation. The parking dance that PROVES the thread hop belongs to
the filedialog scene and is not repeated here — this one owns the round
trip.

NO EXTENSIONS ON THE NAMES, deliberately. A save panel publishes its
name field with the extension hidden when the user's Finder preference
says so, which would make `expect_save_dialog` read the stem on one
machine and the whole name on another — a machine-wide setting deciding
a lane's colour, which the panel view modes already cost this project a
day for. A name with no extension has no stem to differ from.

See guests/rust/save.rs and tools/scenes/save.steps.
"""

import os
import pathlib
import sys
import tempfile
import threading

import kaya

app = kaya.App()

# Both halves compute this identically; see guests/python/filedialog.py's
# note for why it is `tempfile.gettempdir()` and NOT `TMPDIR` — the
# environment variable is a POSIX spelling with no Windows equivalent,
# and reading it there fell back to a literal "/tmp", which aimed the
# guest at the root of the current drive while the interpreter aimed the
# dialog at the real temp directory. Each half computes the directory
# THE WAY ITS OWN LANGUAGE DOES, and this is Python's way. Python runs
# on the three desktops only, so there are no phone arms here.
save_dir = pathlib.Path(tempfile.gettempdir()) / f"kaya-save-{os.getpid()}"
save_dir.mkdir(parents=True, exist_ok=True)
# The file the scene opens, written before anything is shown, plus the
# decoy the picker needs: with ONE file in the directory a dialog
# completes with it when nothing is selected, so `file_choose` would
# pass on a backend that ignored the name entirely. "decoy" sorts
# first, so that backend gets the WRONG file and its five bytes fail
# the byte assertion as well as the name.
(save_dir / "draft").write_text("first draft")
(save_dir / "decoy").write_text("decoy")

# The two capabilities the scene carries: the file the user OPENED, and
# the destination the user later NAMED. Held as handles, never as paths
# — the phones have no re-openable path at all, and the desktops must
# not be allowed to pass with one.
source = None
destination = None


def read_back(picked):
    """Read a handle back through kaya, with Python's own file API. THE
    READ-BACK IS THE ASSERTION in every step of this scene."""
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
        # THE FAILURE D1 EXISTS TO PREVENT reaches the label verbatim:
        # without the create, a save destination answers "No such file
        # or directory" here.
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
    """Run one file operation on a thread of the guest's own and post
    the answer back — a plain daemon thread, because kaya supplies no
    waiting primitive and should not."""
    def worker():
        text = job()
        app.post(lambda: status.set(text))

    threading.Thread(target=worker, name="save-worker", daemon=True).start()


def picked(files):
    global source
    if not files:
        # The empty list IS cancel, faithfully: no platform can confirm
        # an empty selection.
        status.set("open cancelled")
        return
    file = files[0]
    source = file
    work(lambda: f"opened {read_back(file)}")


def saved(file):
    global destination
    if file is None:
        # CANCEL IS None. Nothing was named, so nothing is written and
        # no destination is remembered — the next save-as must ask
        # again.
        status.set("save cancelled")
        return
    destination = file
    work(lambda: f"saved {write_back(file, 'third draft')}")


def open_file():
    # NO FILTER, deliberately: the names in this scene carry no
    # extension, and a filter would only decide a default view the
    # guest still has to validate.
    kaya.pick_file(on_result=picked)


def save_back():
    # SAVE-BACK NEEDS NO DIALOG. The user already chose this file, and
    # the handle they chose it with is writable — the claim this step
    # exists to drive.
    file = source
    work(lambda: f"saved {write_back(file, 'second draft')}")


def save_as():
    # The suggested name the dialog OPENS with; the harness types over
    # it, which is what a save dialog is for. NO FILTER here either, and
    # that one is load-bearing: with allowed content types set,
    # NSSavePanel appends the first allowed extension to an
    # extension-less name.
    kaya.save_file("copy", on_result=saved)


def reopen():
    # BOTH, in order: the file that was opened must still hold the
    # save-back, and the destination must hold the save-as. A save that
    # went to the wrong handle passes every earlier step and fails here.
    first, second = source, destination
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
