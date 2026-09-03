// The save scene, Swift port — guests/rust/save.rs, tools/scenes/save.steps.

import Foundation

let app = KayaApp()

// iOS's picker cannot see the app's container, so the files go in Documents;
// TMPDIR first everywhere else (docs/traps.md).
#if os(iOS)
    let kayaRoot = (NSHomeDirectory() as NSString).appendingPathComponent("Documents")
#else
    let kayaRoot = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
#endif
let saveDir = (kayaRoot as NSString)
    .appendingPathComponent("kaya-save-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(
    atPath: saveDir, withIntermediateDirectories: true)

// The DECOY must sort first and hold different bytes: with one file in the
// directory a dialog completes with it when nothing is selected (docs/traps.md).
FileManager.default.createFile(
    atPath: (saveDir as NSString).appendingPathComponent("draft"),
    contents: Data("first draft".utf8))
FileManager.default.createFile(
    atPath: (saveDir as NSString).appendingPathComponent("decoy"),
    contents: Data("decoy".utf8))

var status: KayaSignal!

// Handles, never paths — `localPath` is empty on both phones.
var source: KayaPickedFile?
var destination: KayaPickedFile?

/// Read a handle back through kaya, with Foundation's own file API.
func readBack(_ file: KayaPickedFile) -> String {
    do {
        let (handle, _) = try file.open(UInt32(KAYA_FILE_MODE_READ))
        let data = handle.readDataToEndOfFile()
        try? handle.close()
        return String(decoding: data, as: UTF8.self)
    } catch {
        return "open failed: \(error)"
    }
}

/// Write `text` through a handle and report what the FILE says afterwards.
/// `KAYA_FILE_MODE_WRITE` truncates; a destination adds create.
func writeBack(_ file: KayaPickedFile, _ text: String) -> String {
    do {
        let (handle, _) = try file.open(UInt32(KAYA_FILE_MODE_WRITE))
        handle.write(Data(text.utf8))
        // Closed before the reopen, so what comes back is the FILE's bytes.
        try? handle.close()
        return readBack(file)
    } catch {
        // Without the create, a save destination answers ENOENT here (D1).
        return "save failed: \(error)"
    }
}

/// Every file operation runs on a thread of the guest's own: open blocks.
func work(_ job: @escaping () -> String) {
    Thread.detachNewThread {
        let text = job()
        app.post { tx in tx.write(status, .str(text)) }
    }
}

app.build { tx in
    tx.window(title: "save")
    status = tx.signal(.str("no file"))

    func picked(_ tx: KayaAppTx, _ files: [KayaPickedFile]) {
        guard let file = files.first else {
            // The empty list IS cancel.
            tx.write(status, .str("open cancelled"))
            return
        }
        source = file
        work { "opened \(readBack(file))" }
    }

    func saved(_ tx: KayaAppTx, _ file: KayaPickedFile?) {
        guard let file else {
            // CANCEL IS nil: nothing named, nothing written, no destination.
            tx.write(status, .str("save cancelled"))
            return
        }
        destination = file
        work { "saved \(writeBack(file, "third draft"))" }
    }

    let root = tx.column {
        tx.setA11yId(tx.label(bind: status), "status")  // label#0
        tx.button("open") { inner in  // button#0
            inner.pickFile(onResult: picked)
        }
        tx.button("save") { _ in  // button#1
            // A missing handle gets its OWN sentence, never a crash: a crashed
            // guest masks the real failure (docs/deferred.md, save-jvm WATCH).
            guard let file = source else {
                tx.write(status, .str("nothing open to save"))
                return
            }
            work { "saved \(writeBack(file, "second draft"))" }
        }
        tx.button("save as") { inner in  // button#2
            // The name the dialog OPENS with; the harness types over it.
            inner.saveFile(suggestedName: "copy", onResult: saved)
        }
        tx.button("reopen") { _ in  // button#3
            // BOTH, in order: a save-as that wrote to the wrong handle passes
            // every earlier step and fails here.
            guard let first = source, let second = destination else {
                tx.write(status, .str("nothing to reopen"))
                return
            }
            work { "reopened \(readBack(first)) \(readBack(second))" }
        }
    }
    tx.mount(root)
}

app.run()
