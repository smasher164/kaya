"""The filedialog scene (tools/scenes/filedialog.steps). THE READ RUNS OFF
THE APP THREAD, because open blocks, and the worker PARKS before posting."""

import os
import pathlib
import sys
import tempfile
import threading

import kaya

app = kaya.App()

# `tempfile.gettempdir()` and NEVER `TMPDIR` — docs/traps.md, the
# POSIX-spelling trap that aimed the guest at the root of a Windows drive.
picked_dir = pathlib.Path(tempfile.gettempdir()) / f"kaya-picked-{os.getpid()}"
picked_dir.mkdir(parents=True, exist_ok=True)
# The decoy MUST sort before picked.txt: Open with nothing selected still
# returns a file (docs/traps.md).
(picked_dir / "picked.txt").write_text("picked bytes")
(picked_dir / "decoy.txt").write_text("decoy")

# The send must NOT wait for the receiver.
released = threading.Event()


def picked(files):
    if not files:
        # The empty list IS cancel.
        status.set("cancelled")
        return

    def worker():
        count = len(files)
        try:
            handle, seekable = files[0].open(kaya.wire.FILE_MODE_READ)
            with handle as f:
                text = f.read().decode()
        except OSError as e:
            text = f"open failed: {e}"
        # Parks: work on the app thread would starve the release click.
        released.wait()
        app.post(lambda: status.set(f"{count} {text}"))

    threading.Thread(target=worker, name="filedialog-reader",
                     daemon=True).start()
    # The handler RETURNED without reading; the scene asserts this text.
    status.set("reading")


def ask():
    # Filters are ADVISORY: the guest still validates what it got.
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
