// The filedialog conformance scene, Swift port — the picker's
// request/result grammar and the capability it hands back (DESIGN.md,
// File dialogs).
//
// WHAT THIS PROVES, and why it goes all the way to the bytes: the
// design's whole claim is that kaya hands over a CAPABILITY and never
// moves the data. So the guest does not assert that a dialog closed —
// it opens the handle it was given, reads the file with an ORDINARY
// FileHandle, and writes what it read into a signal. `expect label#0
// "1 picked bytes"` therefore fails unless a real descriptor came back
// carrying the real file.
//
// THE FILE IS THE GUEST'S OWN, written before anything is shown, so
// guest and interpreter agree on a path with no runner involvement —
// they are the same process. NSTemporaryDirectory() is Foundation's own
// answer, and it honours TMPDIR, which is what makes both halves land
// on the same place without either consulting the other.
//
// THE READ RUNS OFF THE APP THREAD, which is what open tells every
// caller to do: it blocks, and a cloud provider may download the whole
// file before it returns.
//
// The parking is a plain DispatchSemaphore and the worker a detached
// Thread. kaya supplies no waiting primitive and should not: the point
// is that a guest uses its own language's concurrency and hands back
// only the result. The worker PARKS between reading and posting,
// and only a click releases it, so a guest that read inline is caught
// by `expect label#0 "reading"` and one that did the work on the app
// thread wedges everything after.
//
// See guests/rust/filedialog.rs and tools/scenes/filedialog.steps.

import Foundation

let app = KayaApp()

// TMPDIR FIRST. NSTemporaryDirectory() answers with the per-user Darwin
// temp directory (/var/folders/...) and does NOT honour TMPDIR, so the
// guest wrote its files somewhere the interpreter never looked — the
// interpreter computes $TMP the way Rust does, which is TMPDIR when set.
// Java's java.io.tmpdir has the identical flaw and needed the identical
// line. Measured both times by the scene's own "does not exist" guard,
// which is why that guard exists.
let kayaTmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
let pickedDir = (kayaTmp as NSString)
    .appendingPathComponent("kaya-picked-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(
    atPath: pickedDir, withIntermediateDirectories: true)
// THE DECOY IS LOAD-BEARING: with one file in the directory, pressing
// Open with nothing selected returns that file, so `file_choose
// picked.txt` would pass on a backend that ignored the name entirely.
// Measured on GTK. "decoy" sorts before "picked", so a backend that
// skips selection gets the WRONG file, and its five bytes fail the byte
// assertion as well as the name.
try? "picked bytes".write(
    toFile: (pickedDir as NSString).appendingPathComponent("picked.txt"),
    atomically: true, encoding: .utf8)
try? "decoy".write(
    toFile: (pickedDir as NSString).appendingPathComponent("decoy.txt"),
    atomically: true, encoding: .utf8)

// The release gate: the app thread signals, the worker waits. A handler
// that blocked handing this over would fail the very claim being
// tested, so signalling does not wait for the receiver.
let released = DispatchSemaphore(value: 0)

var status: KayaSignal!

app.build { tx in
    tx.window(title: "filedialog")
    status = tx.signal(.str("no file"))

    func picked(_ tx: KayaAppTx, _ files: [KayaPickedFile]) throws {
        if files.isEmpty {
            // The empty list IS cancel. Nothing to read, so no worker
            // and no release.
            try tx.write(status, .str("cancelled"))
            return
        }
        Thread.detachNewThread {
            // THE CLAIM, and it is made HERE rather than in the handler
            // on purpose: the handle crossed a thread boundary, and it
            // is redeemed and read with Foundation's own file API on
            // the thread that received it. kaya is not in this data
            // path, and open is documented to block.
            var text = ""
            do {
                let (file, _) = try files[0].open()
                let data = file.readDataToEndOfFile()
                text = String(decoding: data, as: UTF8.self)
                try? file.close()
            } catch {
                text = "open failed: \(error)"
            }
            // Parks holding the result, standing in for the tail of a
            // slow transfer. Were this work running on the app thread,
            // the release click could never be processed and the whole
            // scene would deadlock — the point.
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
                // guarantee, so a guest still validates what it got.
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
