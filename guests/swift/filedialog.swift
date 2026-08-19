// The filedialog conformance scene, Swift port — the picker's
// request/result grammar and the capability it hands back (DESIGN.md,
// File dialogs). See guests/rust/filedialog.rs and
// tools/scenes/filedialog.steps.
//
// IT GOES ALL THE WAY TO THE BYTES: the guest opens the handle it was
// given, reads with an ORDINARY FileHandle, and reports what it read,
// so `expect label#0 "1 picked bytes"` fails unless a real descriptor
// came back carrying the real file.
//
// THE READ RUNS OFF THE APP THREAD (open blocks), and the worker PARKS
// between reading and posting: only a click releases it, so a guest
// that read inline is caught by `expect label#0 "reading"` and one that
// did the work on the app thread wedges everything after.

import Foundation

let app = KayaApp()

// NOT THE TEMP DIRECTORY ON iOS: $TMP there is the app's own Documents
// (kayaTempDir in swift/KayaSwiftUI.swift), because the picker is a
// remote view controller that browses PROVIDERS and cannot see an
// app's private storage — the clipboard guest draws the same line.
// TMPDIR FIRST EVERYWHERE ELSE — NSTemporaryDirectory() ignores TMPDIR
// (docs/traps.md).
#if os(iOS)
    let kayaTmp = (NSHomeDirectory() as NSString).appendingPathComponent("Documents")
#else
    let kayaTmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
#endif
let pickedDir = (kayaTmp as NSString)
    .appendingPathComponent("kaya-picked-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(
    atPath: pickedDir, withIntermediateDirectories: true)
// THE DECOY IS LOAD-BEARING: with one file in the directory, pressing
// Open with nothing selected returns it, so `file_choose picked.txt`
// would pass on a backend that ignored the name (docs/traps.md).
try? "picked bytes".write(
    toFile: (pickedDir as NSString).appendingPathComponent("picked.txt"),
    atomically: true, encoding: .utf8)
try? "decoy".write(
    toFile: (pickedDir as NSString).appendingPathComponent("decoy.txt"),
    atomically: true, encoding: .utf8)

// The release gate: the app thread signals, the worker waits.
let released = DispatchSemaphore(value: 0)

var status: KayaSignal!

app.build { tx in
    tx.window(title: "filedialog")
    status = tx.signal(.str("no file"))

    func picked(_ tx: KayaAppTx, _ files: [KayaPickedFile]) throws {
        if files.isEmpty {
            // The empty list IS cancel.
            try tx.write(status, .str("cancelled"))
            return
        }
        Thread.detachNewThread {
            // THE CLAIM: the handle crossed a thread boundary, and it is
            // redeemed and read with Foundation's own file API here.
            var text = ""
            do {
                let (file, _) = try files[0].open()
                let data = file.readDataToEndOfFile()
                text = String(decoding: data, as: UTF8.self)
                try? file.close()
            } catch {
                text = "open failed: \(error)"
            }
            // Parks holding the result, standing in for a slow
            // transfer's tail.
            released.wait()
            let count = files.count
            let read = text
            app.post { tx in
                try tx.write(status, .str("\(count) \(read)"))
            }
        }
        // The handler RETURNED without reading.
        try tx.write(status, .str("reading"))
    }

    let root = tx.column {
        tx.setA11yId(tx.label(bind: status), "status")  // label#0
        tx.button(
            "open",
            onClick: { inner in  // button#0
                // ADVISORY on every platform: a default view, never a
                // guarantee.
                inner.pickFiles(filters: [("Text", "txt")], onResult: picked)
            })
        tx.button(
            "open one",
            onClick: { inner in  // button#1
                inner.pickFile(filters: [("Text", "txt")], onResult: picked)
            })
        tx.button(
            "release",
            onClick: { _ in released.signal() })  // button#2
    }
    tx.mount(root)
}

app.run()
