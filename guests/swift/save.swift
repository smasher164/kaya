// The save conformance scene, Swift port — the ROUND TRIP an editor
// walks (docs/save-plan.md D5): open, edit, save, save-as, reopen. See
// guests/rust/save.rs and tools/scenes/save.steps.
//
// EVERY STATUS IS A READ-BACK. The guest writes, closes, reopens through
// the handle kaya gave it, and reports what Foundation read off the
// disk. THE BYTES ARE THE ASSERTION — never a file's NAME, which
// Android's SAF may extend at creation.
//
// The last step reopens BOTH handles, so a save-as that quietly wrote
// back into the ORIGINAL fails here and nowhere else. A save
// destination is openable because the core creates it
// (docs/save-plan.md D1).
//
// NO EXTENSIONS ON THE NAMES and no filter on either request
// (docs/deferred.md, the NSSavePanel extension-hiding entry).

import Foundation

let app = KayaApp()

// iOS's picker cannot see the app's container, so the scene's files go
// in Documents; TMPDIR first everywhere else (docs/traps.md).
#if os(iOS)
    let kayaRoot = (NSHomeDirectory() as NSString).appendingPathComponent("Documents")
#else
    let kayaRoot = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
#endif
let saveDir = (kayaRoot as NSString)
    .appendingPathComponent("kaya-save-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(
    atPath: saveDir, withIntermediateDirectories: true)

// The file the scene opens, plus the DECOY the picker needs: with one
// file in the directory a dialog completes with it when nothing is
// selected. "decoy" sorts first and its bytes differ (docs/traps.md).
FileManager.default.createFile(
    atPath: (saveDir as NSString).appendingPathComponent("draft"),
    contents: Data("first draft".utf8))
FileManager.default.createFile(
    atPath: (saveDir as NSString).appendingPathComponent("decoy"),
    contents: Data("decoy".utf8))

var status: KayaSignal!

// The two capabilities the scene carries, held as HANDLES and never as
// paths — `localPath` is empty on both phones, so a guest that reopened
// by path would work on the desktops and on neither phone.
var source: KayaPickedFile?
var destination: KayaPickedFile?

/// Read a handle back through kaya, with Foundation's own file API.
func readBack(_ file: KayaPickedFile) -> String {
    do {
        let (handle, _) = try file.open(UInt32(FILE_MODE_READ))
        let data = handle.readDataToEndOfFile()
        try? handle.close()
        return String(decoding: data, as: UTF8.self)
    } catch {
        return "open failed: \(error)"
    }
}

/// Write `text` through a handle and report what the file says
/// afterwards. `FILE_MODE_WRITE` truncates; a destination adds create.
func writeBack(_ file: KayaPickedFile, _ text: String) -> String {
    do {
        let (handle, _) = try file.open(UInt32(FILE_MODE_WRITE))
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
            // CANCEL IS nil: nothing named, nothing written, and NO
            // DESTINATION REMEMBERED.
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
            // SAVE-BACK NEEDS NO DIALOG: the handle the user chose with
            // is writable — the claim this step drives.
            guard let file = source else {
                fatalError("kaya: the scene opens a file before saving")
            }
            work { "saved \(writeBack(file, "second draft"))" }
        }
        tx.button("save as") { inner in  // button#2
            // The suggested name the dialog OPENS with; the harness types
            // over it.
            inner.saveFile(suggestedName: "copy", onResult: saved)
        }
        tx.button("reopen") { _ in  // button#3
            // BOTH, in order: a save that went to the wrong handle passes
            // every earlier step and fails here.
            guard let first = source, let second = destination else {
                fatalError("kaya: the scene opens a file and saves as before reopening")
            }
            work { "reopened \(readBack(first)) \(readBack(second))" }
        }
    }
    tx.mount(root)
}

app.run()
