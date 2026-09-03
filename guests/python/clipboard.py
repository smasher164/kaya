"""The clipboard conformance scene (tools/scenes/clipboard.steps): a FOREIGN
tool seeds and reads, because kaya reading its own bytes proves nothing."""

import os
import pathlib
import sys
import tempfile
import threading

import kaya

app = kaya.App()

# `tempfile.gettempdir()` and NEVER `TMPDIR` — docs/traps.md, the
# POSIX-spelling trap that wrote to the root of a Windows drive.
scene_dir = pathlib.Path(tempfile.gettempdir()) / f"kaya-clip-{os.getpid()}"
scene_dir.mkdir(parents=True, exist_ok=True)

# A real 4x4 PNG: the scene asserts "4x4" through a FOREIGN decoder.
PIXEL_PNG = bytes([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,  # signature
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,  # IHDR length + type
    0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,  # 4 x 4
    0x08, 0x02, 0x00, 0x00, 0x00, 0x26, 0x93, 0x09,  # 8-bit rgb + crc
    0x29, 0x00, 0x00, 0x00, 0x14, 0x49, 0x44, 0x41,  # IDAT length + type
    0x54, 0x78, 0xDA, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
    0x47, 0x48, 0x4C, 0x74, 0xDE, 0x7F, 0x24, 0x00,
    0x00, 0xD2, 0x6F, 0x17, 0xE9, 0x51, 0xBB, 0x23,
    0x2D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
    0x44, 0xAE, 0x42, 0x60, 0x82,  # IEND + crc
])

# Reverse-DNS and space-free: it reaches every registry VERBATIM.
NOTE_ID = "dev.kaya/note"
# NO QUOTES IN THE PAYLOAD: the step grammar has no \" escape.
NOTE_BYTES = b"note=1"

(scene_dir / "pixel.png").write_bytes(PIXEL_PNG)
(scene_dir / "pasted.txt").write_text("pasted bytes")


def copy_rich():
    # One clip, four representations; kaya derives none from any other.
    kaya.copy(text="kaya clip", html="<b>kaya</b> clip",
              image=PIXEL_PNG, custom={NOTE_ID: NOTE_BYTES})
    status.set("copied")


def answered(clip):
    match clip:
        # EMPTY IS THE UNIVERSAL NO; no platform says which cause.
        case None:
            status.set("empty")
        case kaya.Representation.Text(text):
            status.set(f"text {text}")
        case kaya.Representation.Html(html):
            status.set(f"html {html}")
        case kaya.Representation.Custom(ident, body):
            status.set(f"custom {ident} {body.decode()}")
        case kaya.Representation.Image(data):
            # A foreign DECODER's size: byte counts differ per host.
            kaya.copy(image=data)
            status.set("image")
        case kaya.Representation.Files(files):
            if not files:
                status.set("files none")
                return

            def worker():
                # OFF THE APP THREAD: open() blocks.
                name = files[0].name
                try:
                    handle, _seekable = files[0].open(kaya.wire.FILE_MODE_READ)
                    with handle as f:
                        text = f.read().decode()
                except OSError as e:
                    text = f"open failed: {e}"
                app.post(lambda: status.set(f"files {name} {text}"))

            threading.Thread(target=worker, name="clipboard-reader",
                             daemon=True).start()
            status.set("reading")


def read_custom():
    kaya.read_clipboard([NOTE_ID], on_result=answered)


def read_text():
    kaya.read_clipboard([kaya.ACCEPT_TEXT], on_result=answered)


def read_image():
    kaya.read_clipboard([kaya.ACCEPT_IMAGE], on_result=answered)


def read_files():
    kaya.read_clipboard([kaya.ACCEPT_FILES], on_result=answered)


def pasted(clip):
    match clip:
        case kaya.Representation.Text(text):
            status.set(f"pasted {text}")
        case other:
            status.set(f"pasted {other!r}")


def row_pasted(key, clip):
    # Printing the key proves this dispatched as an INSTANCE occurrence.
    match clip:
        case kaya.Representation.Text(text):
            row_status.set(f"row {key} pasted {text}")
        case other:
            row_status.set(f"row {key} pasted {other!r}")


with app.window(title="clipboard"):
    with app.menu("Edit"):
        kaya.item("Cut", role=kaya.ROLE_CUT)
        kaya.item("Copy", role=kaya.ROLE_COPY)
        kaya.item("Paste", role=kaya.ROLE_PASTE)

    status = kaya.signal("ready")
    row_status = kaya.signal("")
    with kaya.column():
        kaya.label(bind=status).a11y_id("status")          # label#0
        kaya.button("copy", on_click=copy_rich)            # button#0
        kaya.button("read custom", on_click=read_custom)   # button#1
        kaya.button("read text", on_click=read_text)       # button#2
        kaya.button("read image", on_click=read_image)     # button#3
        kaya.button("read files", on_click=read_files)     # button#4
        kaya.button("focus rich",
                    on_click=lambda: rich.focus())         # button#5
        kaya.button("focus plain",
                    on_click=lambda: plain.focus())        # button#6

        # Declares what it takes, so a paste lands in the hook.
        rich = kaya.entry().accepts(kaya.ACCEPT_TEXT).on_paste(pasted)
        rich.a11y_id("rich")                               # entry#0
        # Declares nothing, so the platform inserts and on_change reports.
        plain = kaya.entry().a11y_id("plain")              # entry#1

        # On a STAMPED copy the accept list rides the TEMPLATE.
        kaya.label(bind=row_status).a11y_id("row-status")  # label#1
        rows = kaya.collection()
        for row in rows:
            kaya.entry().accepts(kaya.ACCEPT_TEXT).on_paste(row_pasted)
        rows.insert("r1", "")                              # entry#2

sys.exit(app.run())
