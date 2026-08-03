// The clipboard conformance scene, Swift port — one clip in several
// representations, and the privileged read that takes one back
// (DESIGN.md, Clipboard; docs/clipboard-plan.md).
//
// EVERY ASSERTION CROSSES A PROCESS BOUNDARY, which is the whole design
// of this scene. kaya's representation set is closed because the
// LOWERINGS are the hard part — CF_HTML's mandatory offset header,
// Android's content:// URI for an image, CF_HDROP's double-NUL struct —
// and a check where kaya reads what kaya wrote parses its own malformed
// header perfectly happily. That is not merely less coverage: it is a
// check that cannot fail for the reason the design exists.
//
// THE ONE EXCEPTION IS THE CUSTOM FORMAT, deliberately. No stock tool
// on any platform writes an app-defined type, so the guest copies one
// and reads it back, with the foreign reader confirming from outside
// that the bytes really are there under that id.
//
// THE IMAGE IS ASSERTED AS A DECODED SIZE, never as bytes: every host
// re-encodes freely between image types, so a byte count would be a
// different number on every lane for one picture.
//
// See guests/rust/clipboard.swift's canonical semantics in
// guests/rust/clipboard.rs and tools/scenes/clipboard.steps.

import Foundation

let app = KayaApp()

// TMPDIR FIRST. NSTemporaryDirectory() answers with the per-user Darwin
// temp directory (/var/folders/...) and does NOT honour TMPDIR, so a
// guest that trusted it wrote its files somewhere the interpreter never
// looked — the interpreter computes $TMP the way Rust does, which is
// TMPDIR when set. Measured by the filedialog scene, the hard way.
let kayaTmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
let sceneDir = (kayaTmp as NSString)
    .appendingPathComponent("kaya-clip-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(
    atPath: sceneDir, withIntermediateDirectories: true)

// A 4x4 PNG, spelled out rather than generated: the scene asserts "4x4"
// through a foreign decoder, so the picture has to be a real encoded
// image whose size is knowable from the script. Written to disk for the
// seeding tool AND handed to copy() as bytes — the same picture both
// ways.
let pixelPNG: [UInt8] = [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,  // signature
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,  // IHDR length + type
    0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,  // 4 x 4
    0x08, 0x02, 0x00, 0x00, 0x00, 0x26, 0x93, 0x09,  // 8-bit rgb + crc
    0x29, 0x00, 0x00, 0x00, 0x14, 0x49, 0x44, 0x41,  // IDAT length + type
    0x54, 0x78, 0xDA, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
    0x47, 0x48, 0x4C, 0x74, 0xDE, 0x7F, 0x24, 0x00,
    0x00, 0xD2, 0x6F, 0x17, 0xE9, 0x51, 0xBB, 0x23,
    0x2D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
    0x44, 0xAE, 0x42, 0x60, 0x82,  // IEND + crc
]

// The app-defined format's id: reverse-DNS and space-free, because it
// reaches every platform's own registry VERBATIM — a UTI on Apple,
// RegisterClipboardFormat on Windows, a target atom on X11 and Wayland,
// a MIME type on Android.
let noteID = "dev.kaya/note"
// NO QUOTES IN THE PAYLOAD, and the reason is the script rather than
// the clipboard: the step grammar's escapes are \n, \r and \\ in all
// three interpreters, with no \" — so a quoted byte could not be
// spelled in the expectation.
let noteBytes: [UInt8] = Array("note=1".utf8)

FileManager.default.createFile(
    atPath: (sceneDir as NSString).appendingPathComponent("pixel.png"),
    contents: Data(pixelPNG))
FileManager.default.createFile(
    atPath: (sceneDir as NSString).appendingPathComponent("pasted.txt"),
    contents: Data("pasted bytes".utf8))

var status: KayaSignal!
var rich: KayaWidget!
var plain: KayaWidget!

app.build { tx in
    // THE GESTURE LAYER'S DECLARATION, and an app writes nothing else
    // for it: the Paste command lowers to the platform's own, acts on
    // whatever is focused, and works out its own enablement. kaya has
    // no selection API, which is exactly why copy of a selection has to
    // be a command rather than something an app assembles out of the
    // data layer.
    let edit = tx.menu(
        "Edit",
        items: [
            tx.item("Cut", role: KayaAppTx.roleCut),
            tx.item("Copy", role: KayaAppTx.roleCopy),
            tx.item("Paste", role: KayaAppTx.rolePaste),
        ])
    tx.window(title: "clipboard", menus: [edit])

    status = tx.signal(.str("ready"))

    func answered(_ tx: KayaAppTx, _ clip: KayaRepresentation?) throws {
        switch clip {
        // EMPTY IS THE UNIVERSAL NO, and the guest does not try to tell
        // its four causes apart — denied, unfocused, absent, or nothing
        // this read accepted. The platforms deliberately decline to say.
        case nil:
            tx.write(status, .str("empty"))
        case .text(let text):
            tx.write(status, .str("text \(text)"))
        case .html(let html):
            tx.write(status, .str("html \(html)"))
        case .custom(let id, let bytes):
            tx.write(
                status, .str("custom \(id) \(String(decoding: bytes, as: UTF8.self))"))
        case .image(let bytes):
            // STRAIGHT BACK OUT, because the assertion that matters is
            // a foreign DECODER's: the byte count differs per host for
            // one picture, and the decoded size does not.
            tx.copy().image(bytes).send()
            tx.write(status, .str("image"))
        case .files(let files):
            guard let file = files.first else {
                tx.write(status, .str("files none"))
                return
            }
            Thread.detachNewThread {
                // OFF THE APP THREAD, which is what open documents: it
                // blocks, and a pasted file is no different from a
                // picked one — it IS a picked one, the same capability
                // arriving through a second door.
                var text = ""
                do {
                    let (handle, _) = try file.open()
                    text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
                    try? handle.close()
                } catch {
                    text = "open failed: \(error)"
                }
                let name = file.name
                let read = text
                app.post { tx in
                    tx.write(status, .str("files \(name) \(read)"))
                }
            }
            tx.write(status, .str("reading"))
        }
    }

    let root = tx.column {
        tx.setA11yId(tx.label(bind: status), "status")  // label#0
        tx.button(
            "copy",
            onClick: { inner in  // button#0
                // ONE CLIP, FOUR REPRESENTATIONS. kaya derives none of
                // them from any other: whether list bullets survive
                // html-to-text is this app's decision, so it spells out
                // both. The order they go on the wire is kaya's, not
                // this chain's — descending richness, which is
                // preference order on every host that has one.
                inner.copy()
                    .text("kaya clip")
                    .html("<b>kaya</b> clip")
                    .image(pixelPNG)
                    .custom(noteID, noteBytes)
                    .send()
                inner.write(status, .str("copied"))
            })
        tx.button(
            "read custom",
            onClick: { inner in  // button#1
                inner.readClipboard().custom(noteID).onResult(answered).send()
            })
        tx.button(
            "read text",
            onClick: { inner in  // button#2
                inner.readClipboard().text().onResult(answered).send()
            })
        tx.button(
            "read image",
            onClick: { inner in  // button#3
                inner.readClipboard().image().onResult(answered).send()
            })
        tx.button(
            "read files",
            onClick: { inner in  // button#4
                inner.readClipboard().files().onResult(answered).send()
            })
        tx.button(
            "focus rich",
            onClick: { inner in inner.focus(rich) })  // button#5
        tx.button(
            "focus plain",
            onClick: { inner in inner.focus(plain) })  // button#6

        // DECLARES WHAT IT TAKES, so a paste lands in the hook and this
        // app decides what to do with it.
        rich = tx.entry()  // entry#0
        tx.setAccepts(rich, [KayaAppTx.acceptText])
        tx.setA11yId(rich, "rich")
        tx.onPaste(rich) { inner, clip in
            // THE SAME SHAPE THE READ ANSWERS WITH, and free where the
            // read is not: a gesture is its own authorisation, so no
            // platform charges a prompt for this one.
            if case .text(let text) = clip {
                inner.write(status, .str("pasted \(text)"))
                return
            }
            inner.write(status, .str("pasted \(clip)"))
        }

        // DECLARES NOTHING, so the platform's own insertion happens and
        // the field's ordinary change path reports it — which is what a
        // plain text editor gets for free.
        plain = tx.entry()  // entry#1
        tx.setA11yId(plain, "plain")
    }
    tx.mount(root)
}

app.run()
