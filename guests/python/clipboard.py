"""The clipboard conformance scene, Python port — one clip in several
representations, and the privileged read that takes one back (DESIGN.md,
Clipboard; docs/clipboard-plan.md).

EVERY ASSERTION CROSSES A PROCESS BOUNDARY, which is the whole design of
this scene. kaya's representation set is closed because the LOWERINGS
are the hard part — CF_HTML's mandatory offset header, Android's
content:// URI for an image, CF_HDROP's double-NUL struct — and a check
where kaya reads what kaya wrote parses its own malformed header
perfectly happily. That is not merely less coverage: it is a check that
cannot fail for the reason the design exists.

THE ONE EXCEPTION IS THE CUSTOM FORMAT, deliberately. No stock tool on
any platform writes an app-defined type, so the guest copies one and
reads it back, with the foreign reader confirming from outside that the
bytes really are there under that id.

THE IMAGE IS ASSERTED AS A DECODED SIZE, never as bytes: every host
re-encodes freely between image types, so a byte count would be a
different number on every lane for one picture.

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

# Both halves compute this identically, the filedialog rule: guest and
# interpreter are the same process, so they agree on a path with no
# runner involvement, and the pid keeps parallel legs from colliding.
# `tempfile.gettempdir()` and NOT `TMPDIR` — the environment variable is
# a POSIX spelling with no Windows equivalent, and reading it sent an
# earlier guest's files to the root of the current drive.
scene_dir = pathlib.Path(tempfile.gettempdir()) / f"kaya-clip-{os.getpid()}"
scene_dir.mkdir(parents=True, exist_ok=True)

# A 4x4 PNG, spelled out rather than generated: the scene asserts "4x4"
# through a foreign decoder, so the picture has to be a real encoded
# image whose size is knowable from the script. Written to disk for the
# seeding tool AND handed to copy() as bytes — the same picture both
# ways.
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

# The app-defined format's id: reverse-DNS and space-free, because it
# reaches every platform's own registry VERBATIM — a UTI on Apple,
# RegisterClipboardFormat on Windows, a target atom on X11 and Wayland,
# a MIME type on Android.
NOTE_ID = "dev.kaya/note"
# NO QUOTES IN THE PAYLOAD, and the reason is the script rather than the
# clipboard: the step grammar's escapes are \n, \r and \\ in all three
# interpreters, with no \" — so a quoted byte could not be spelled in the
# expectation.
NOTE_BYTES = b"note=1"

(scene_dir / "pixel.png").write_bytes(PIXEL_PNG)
(scene_dir / "pasted.txt").write_text("pasted bytes")


def copy_rich():
    # ONE CLIP, FOUR REPRESENTATIONS. kaya derives none of them from any
    # other: whether list bullets survive html-to-text is this app's
    # decision, so it spells out both. The order they go on the wire is
    # kaya's, not this call's — descending richness, which is preference
    # order on every host that has one.
    kaya.copy(text="kaya clip", html="<b>kaya</b> clip",
              image=PIXEL_PNG, custom={NOTE_ID: NOTE_BYTES})
    status.set("copied")


def answered(clip):
    match clip:
        # EMPTY IS THE UNIVERSAL NO, and the guest does not try to tell
        # its four causes apart — denied, unfocused, absent, or nothing
        # this read accepted. The platforms deliberately decline to say.
        case None:
            status.set("empty")
        case kaya.Representation.Text(text):
            status.set(f"text {text}")
        case kaya.Representation.Html(html):
            status.set(f"html {html}")
        case kaya.Representation.Custom(ident, body):
            status.set(f"custom {ident} {body.decode()}")
        case kaya.Representation.Image(data):
            # STRAIGHT BACK OUT, because the assertion that matters is a
            # foreign DECODER's: the byte count differs per host for one
            # picture, and the decoded size does not.
            kaya.copy(image=data)
            status.set("image")
        case kaya.Representation.Files(files):
            if not files:
                status.set("files none")
                return

            def worker():
                # OFF THE APP THREAD, which is what open() documents: it
                # blocks, and a pasted file is no different from a picked
                # one — it IS a picked one, the same capability arriving
                # through a second door.
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
    # THE SAME SHAPE THE READ ANSWERS WITH, and free where the read is
    # not: a gesture is its own authorisation, so no platform charges a
    # prompt for this one.
    match clip:
        case kaya.Representation.Text(text):
            status.set(f"pasted {text}")
        case other:
            status.set(f"pasted {other!r}")


def row_pasted(key, clip):
    # THE COPY'S OWN KEY RIDES IN FRONT of the payload — "r1" here, the
    # shape every node handler receives — and printing it is the proof
    # the paste dispatched as an INSTANCE occurrence and not a live one.
    match clip:
        case kaya.Representation.Text(text):
            row_status.set(f"row {key} pasted {text}")
        case other:
            row_status.set(f"row {key} pasted {other!r}")


with app.window(title="clipboard"):
    # THE GESTURE LAYER'S DECLARATION, and an app writes nothing else
    # for it: the Paste command lowers to the platform's own, acts on
    # whatever is focused, and works out its own enablement. kaya has no
    # selection API, which is exactly why copy of a selection has to be
    # a command rather than something an app assembles out of the data
    # layer.
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
        # The lambdas name fields declared below: the declaration order
        # is the scene's, shared verbatim with every other language, and
        # a handler runs long after the column is built.
        kaya.button("focus rich",
                    on_click=lambda: rich.focus())         # button#5
        kaya.button("focus plain",
                    on_click=lambda: plain.focus())        # button#6

        # DECLARES WHAT IT TAKES, so a paste lands in the hook and this
        # app decides what to do with it.
        rich = kaya.entry().accepts(kaya.ACCEPT_TEXT).on_paste(pasted)
        rich.a11y_id("rich")                               # entry#0
        # DECLARES NOTHING, so the platform's own insertion happens and
        # the field's ordinary change path reports it — which is what a
        # plain text editor gets for free.
        plain = kaya.entry().a11y_id("plain")              # entry#1

        # A STAMPED paste target: the same two-door contract one tier
        # down. The accept list comes from the TEMPLATE — the prop no
        # binding could spell before docs/tpl-props-plan.md P1 — and the
        # paste arrives as an INSTANCE occurrence carrying the copy's own
        # key, which is what row_status prints. This is the branch no
        # backend had ever fired: the registrar existed in seven bindings
        # and the dispatch in all of them, but a paste only reaches a
        # widget that declared an accept list, and no stamped copy could.
        kaya.label(bind=row_status).a11y_id("row-status")  # label#1
        rows = kaya.collection()
        for row in rows:
            kaya.entry().accepts(kaya.ACCEPT_TEXT).on_paste(row_pasted)
        rows.insert("r1", "")                              # entry#2

sys.exit(app.run())
