// The clipboard conformance scene, Swift port — one clip in several
// representations, and the privileged read that takes one back
// (DESIGN.md, Clipboard; docs/clipboard-plan.md). See
// guests/rust/clipboard.rs and tools/scenes/clipboard.steps.
//
// EVERY ASSERTION CROSSES A PROCESS BOUNDARY: a check where kaya reads
// what kaya wrote parses its own malformed header happily, so it cannot
// fail for the reason the design exists. The custom format is the one
// exception — no stock tool writes an app-defined type, so a foreign
// reader confirms the bytes from outside. The image is asserted as a
// DECODED SIZE, never as bytes, because every host re-encodes freely.

import Foundation

let app = KayaApp()

// NOT THE TEMP DIRECTORY ON iOS: $TMP there is the app's own Documents
// (kayaTempDir in swift/KayaSwiftUI.swift), because the outside process
// that seeds and reads these files cannot see an app's private storage.
// TMPDIR FIRST EVERYWHERE ELSE — NSTemporaryDirectory() ignores TMPDIR
// (docs/traps.md).
#if os(iOS)
    let kayaTmp = (NSHomeDirectory() as NSString).appendingPathComponent("Documents")
#else
    let kayaTmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
#endif
let sceneDir = (kayaTmp as NSString)
    .appendingPathComponent("kaya-clip-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(
    atPath: sceneDir, withIntermediateDirectories: true)

// A 4x4 PNG, spelled out rather than generated: the scene asserts "4x4"
// through a foreign decoder, so it has to be a real encoded image.
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
// reaches every platform's own registry VERBATIM.
let noteID = "dev.kaya/note"
// NO QUOTES IN THE PAYLOAD: the step grammar's escapes are \n, \r and
// \\ in all three interpreters, so a quoted byte has no spelling.
let noteBytes: [UInt8] = Array("note=1".utf8)

FileManager.default.createFile(
    atPath: (sceneDir as NSString).appendingPathComponent("pixel.png"),
    contents: Data(pixelPNG))
FileManager.default.createFile(
    atPath: (sceneDir as NSString).appendingPathComponent("pasted.txt"),
    contents: Data("pasted bytes".utf8))

var status: KayaSignal!
var rowStatus: KayaSignal!
var rich: KayaWidget!
var plain: KayaWidget!

app.build { tx in
    let edit = tx.menu(
        "Edit",
        items: [
            tx.item("Cut", role: KayaAppTx.roleCut),
            tx.item("Copy", role: KayaAppTx.roleCopy),
            tx.item("Paste", role: KayaAppTx.rolePaste),
        ])
    tx.window(title: "clipboard", menus: [edit])

    status = tx.signal(.str("ready"))
    rowStatus = tx.signal(.str(""))

    func answered(_ tx: KayaAppTx, _ clip: KayaRepresentation?) throws {
        switch clip {
        // EMPTY IS THE UNIVERSAL NO; the guest does not try to tell its
        // four causes apart, because the platforms decline to say.
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
            // Straight back out — a foreign DECODER makes the assertion.
            tx.copy().image(bytes).send()
            tx.write(status, .str("image"))
        case .files(let files):
            guard let file = files.first else {
                tx.write(status, .str("files none"))
                return
            }
            Thread.detachNewThread {
                // OFF THE APP THREAD: open blocks, and a pasted file is a
                // picked one arriving through a second door.
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
                // ONE CLIP, FOUR REPRESENTATIONS, and kaya derives none
                // from any other. Wire order is kaya's — descending
                // richness — not this chain's.
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

        // Declares what it takes, so a paste lands in the hook.
        rich = tx.entry()  // entry#0
        tx.setAccepts(rich, [KayaAppTx.acceptText])
        tx.setA11yId(rich, "rich")
        tx.onPaste(rich) { inner, clip in
            if case .text(let text) = clip {
                inner.write(status, .str("pasted \(text)"))
                return
            }
            inner.write(status, .str("pasted \(clip)"))
        }

        // Declares nothing, so the platform's own insertion happens and
        // the field's ordinary change path reports it.
        plain = tx.entry()  // entry#1
        tx.setA11yId(plain, "plain")

        // The accept list is declared on the TEMPLATE, and that
        // declaration is what turns the node hook on at all
        // (docs/tpl-props-plan.md §1).
        tx.setA11yId(tx.label(bind: rowStatus), "row-status")  // label#1
        let notes = tx.collection()
        tx.each(notes) { t in
            let note = t.entry()  // entry#2, one stamped copy
            t.setAccepts(note, [KayaAppTx.acceptText])
            tx.onPaste(note) { inner, keys, clip in
                // The dispatch only routes a NON-EMPTY path to a node
                // handler, so the first key is there by construction.
                if case .text(let text) = clip, case .str(let key) = keys[0] {
                    inner.write(rowStatus, .str("row \(key) pasted \(text)"))
                    return
                }
                inner.write(rowStatus, .str("row \(keys[0]) pasted \(clip)"))
            }
        }
        tx.insert(notes, .str("r1"), .str(""))
    }
    tx.mount(root)
}

app.run()
