"""The clipboard conformance scene, Python port — one clip in several
representations, and the privileged read that takes one back (DESIGN.md,
Clipboard; docs/clipboard-plan.md).

Assertions cross a process boundary: a FOREIGN tool seeds and reads the
clipboard, because a check where kaya reads what kaya wrote parses its
own malformed header happily. The custom format is the one exception (no
stock tool writes an app-defined type), and the image is asserted as a
DECODED SIZE, never bytes — every host re-encodes freely.

Canonical semantics in guests/rust/clipboard.rs; the byte-frozen
contract in tools/scenes/clipboard.steps.
"""

import os
import pathlib
import sys
import tempfile
import threading

import kaya

app = kaya.App()

# Guest and interpreter compute this identically, with no runner
# involvement; the pid keeps parallel legs from colliding.
# `tempfile.gettempdir()` and NEVER `TMPDIR` — see docs/traps.md, the
# POSIX-spelling trap that wrote a guest's files to the root of the
# current drive on Windows.
scene_dir = pathlib.Path(tempfile.gettempdir()) / f"kaya-clip-{os.getpid()}"
scene_dir.mkdir(parents=True, exist_ok=True)

# A real encoded 4x4 PNG, spelled out rather than generated: the scene
# asserts "4x4" through a foreign decoder. Written to disk for the
# seeding tool AND handed to copy() as bytes.
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

# Reverse-DNS and space-free: this id reaches every platform's own
# registry VERBATIM (a UTI, RegisterClipboardFormat, an X11 target atom,
# an Android MIME type).
NOTE_ID = "dev.kaya/note"
# NO QUOTES IN THE PAYLOAD: the step grammar's escapes are \n, \r and \\
# with no \" (crates/kaya/src/harness.rs), so a quoted byte could not be
# spelled in the expectation.
NOTE_BYTES = b"note=1"

(scene_dir / "pixel.png").write_bytes(PIXEL_PNG)
(scene_dir / "pasted.txt").write_text("pasted bytes")


def copy_rich():
    # One clip, four representations; kaya derives none from any other, so
    # the app spells out both text and html. Wire order is kaya's.
    kaya.copy(text="kaya clip", html="<b>kaya</b> clip",
              image=PIXEL_PNG, custom={NOTE_ID: NOTE_BYTES})
    status.set("copied")


def answered(clip):
    match clip:
        # Empty is the universal no; its four causes (denied, unfocused,
        # absent, nothing accepted) are not distinguishable — the
        # platforms decline to say, so the guest does not guess.
        case None:
            status.set("empty")
        case kaya.Representation.Text(text):
            status.set(f"text {text}")
        case kaya.Representation.Html(html):
            status.set(f"html {html}")
        case kaya.Representation.Custom(ident, body):
            status.set(f"custom {ident} {body.decode()}")
        case kaya.Representation.Image(data):
            # Straight back out: the assertion that matters is a foreign
            # decoder's size, not a byte count.
            kaya.copy(image=data)
            status.set("image")
        case kaya.Representation.Files(files):
            if not files:
                status.set("files none")
                return

            def worker():
                # OFF THE APP THREAD: open() blocks, and a pasted file is
                # a picked file arriving through a second door.
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
    # The same shape the read answers with, and unprivileged: a gesture
    # is its own authorisation.
    match clip:
        case kaya.Representation.Text(text):
            status.set(f"pasted {text}")
        case other:
            status.set(f"pasted {other!r}")


def row_pasted(key, clip):
    # The copy's own key rides in front of the payload; printing it is
    # what proves the paste dispatched as an INSTANCE occurrence.
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
        # The lambdas name fields declared BELOW; the declaration order is
        # the scene's, and a handler runs long after the column is built.
        kaya.button("focus rich",
                    on_click=lambda: rich.focus())         # button#5
        kaya.button("focus plain",
                    on_click=lambda: plain.focus())        # button#6

        # Declares what it takes, so a paste lands in the hook.
        rich = kaya.entry().accepts(kaya.ACCEPT_TEXT).on_paste(pasted)
        rich.a11y_id("rich")                               # entry#0
        # Declares nothing, so the platform inserts and the field's
        # ordinary change path reports it.
        plain = kaya.entry().a11y_id("plain")              # entry#1

        # A STAMPED paste target: the accept list comes from the TEMPLATE
        # (docs/tpl-props-plan.md P1) and the paste arrives as an INSTANCE
        # occurrence carrying the copy's key.
        kaya.label(bind=row_status).a11y_id("row-status")  # label#1
        rows = kaya.collection()
        for row in rows:
            kaya.entry().accepts(kaya.ACCEPT_TEXT).on_paste(row_pasted)
        rows.insert("r1", "")                              # entry#2

sys.exit(app.run())
