// The save conformance scene, Swift port — the ROUND TRIP an editor
// actually walks (docs/save-plan.md D5), which is open, edit, save,
// save-as, reopen. See guests/rust/save.rs and tools/scenes/save.steps.
//
// WHAT THIS PROVES, and why none of it is about a dialog closing:
//
// 1. **Save-back works.** Writing through the handle the OPEN picker
//    handed over — the thing DESIGN.md has claimed since the picker
//    landed and that no scene, leg or test had ever driven.
// 2. **A save destination is openable at all.** A save dialog on this
//    platform answers with a name for a file NOBODY HAS MADE (measured:
//    `exists=false` after a clean Save), so opening it would fail with
//    "No such file or directory" for a file the user just named. The
//    core's save destination creates; docs/save-plan.md D1 is the
//    decision, and this scene is where it shows.
// 3. **The two files stay different.** The last step reopens BOTH
//    handles and reports both contents, so a save-as that quietly wrote
//    back into the ORIGINAL — the plausible bug, since the guest is
//    holding two handles that look alike — fails here and nowhere else.
// 4. **Cancel is nothing, and the dialog id retires.** The scene shows a
//    save dialog, cancels it, and shows another. A cancel that leaked
//    the live slot would panic on the second show.
//
// EVERY STATUS IS A READ-BACK. The guest never reports what it hoped it
// wrote: it writes, closes, reopens through the handle kaya gave it, and
// puts what Foundation reads off the disk into the signal. A write that
// returned success and landed nowhere is exactly the failure "save" has,
// and only reopening can see it. THE BYTES ARE THE ASSERTION — never a
// file's NAME, which Android's SAF may extend at creation.
//
// THE WORK RUNS OFF THE APP THREAD, which is what `open` tells every
// caller to do: it blocks, and a cloud provider may download the whole
// file first. The parking dance that PROVES the thread hop belongs to
// the filedialog scene and is not repeated here — this one owns the
// round trip.
//
// NO EXTENSIONS ON THE NAMES, deliberately. NSSavePanel publishes the
// name field's value with the extension HIDDEN when the user's Finder
// preference says so, which would make `expect_save_dialog` read the
// stem on one machine and the whole name on another — a machine-wide
// setting deciding a lane's colour, which the panel view modes already
// cost this project a day for. A name with no extension has no stem to
// differ from, on any platform. Neither request carries a filter for the
// same reason: with `allowedContentTypes` set, NSSavePanel appends the
// first allowed extension to an extension-less name.

import Foundation

let app = KayaApp()

// THE PICKER'S OWN ROOT RULE, and the filedialog scene's module note
// carries the reasoning per platform: iOS's picker cannot see the app's
// container, so the scene's files go in the app's Documents collection
// the document browser lists. TMPDIR FIRST EVERYWHERE ELSE —
// NSTemporaryDirectory() answers with the per-user Darwin temp directory
// and does NOT honour TMPDIR, so a guest that trusted it writes where
// the interpreter never looks (the interpreter computes $TMP the way
// Rust does, which is TMPDIR when set). Measured by the filedialog
// scene, the hard way.
#if os(iOS)
    let kayaRoot = (NSHomeDirectory() as NSString).appendingPathComponent("Documents")
#else
    let kayaRoot = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
#endif
let saveDir = (kayaRoot as NSString)
    .appendingPathComponent("kaya-save-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(
    atPath: saveDir, withIntermediateDirectories: true)

// The file the scene opens, written before anything is shown, plus the
// decoy the picker needs: with ONE file in the directory a dialog
// completes with it when nothing is selected, so `file_choose` would
// pass on a backend that ignored the name. "decoy" sorts first, so that
// backend gets the WRONG file and its five bytes fail the byte
// assertion too.
FileManager.default.createFile(
    atPath: (saveDir as NSString).appendingPathComponent("draft"),
    contents: Data("first draft".utf8))
FileManager.default.createFile(
    atPath: (saveDir as NSString).appendingPathComponent("decoy"),
    contents: Data("decoy".utf8))

var status: KayaSignal!

// The two capabilities the scene carries: the file the user OPENED, and
// the destination the user later NAMED. Held as HANDLES and never as
// paths — `localPath` is empty on both phones, so a guest that reopened
// by path would work on the desktops and on neither phone.
var source: KayaPickedFile?
var destination: KayaPickedFile?

/// Read a handle back through kaya, with Foundation's own file API.
/// THE READ-BACK IS THE ASSERTION in every step of this scene.
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
/// afterwards. `FILE_MODE_WRITE` truncates, on a picked file and on a
/// save destination alike — the destination only adds the create.
func writeBack(_ file: KayaPickedFile, _ text: String) -> String {
    do {
        let (handle, _) = try file.open(UInt32(FILE_MODE_WRITE))
        handle.write(Data(text.utf8))
        // CLOSED BEFORE THE REOPEN, so what comes back is the FILE's
        // bytes rather than a buffer's.
        try? handle.close()
        return readBack(file)
    } catch {
        // THE FAILURE D1 EXISTS TO PREVENT reaches the label verbatim:
        // without the create, a save destination answers ENOENT here.
        return "save failed: \(error)"
    }
}

/// Every file operation runs on a thread of the guest's own, because
/// `open` blocks; the answer comes back through `post`.
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
            // The empty list IS cancel: no platform can confirm an empty
            // selection, so it needs no sentinel.
            tx.write(status, .str("open cancelled"))
            return
        }
        source = file
        work { "opened \(readBack(file))" }
    }

    func saved(_ tx: KayaAppTx, _ file: KayaPickedFile?) {
        guard let file else {
            // CANCEL IS nil. Nothing was named, so nothing is written
            // and NO DESTINATION IS REMEMBERED.
            tx.write(status, .str("save cancelled"))
            return
        }
        destination = file
        work { "saved \(writeBack(file, "third draft"))" }
    }

    let root = tx.column {
        tx.setA11yId(tx.label(bind: status), "status")  // label#0
        tx.button("open") { inner in  // button#0
            // NO FILTER. A save panel with allowed types appends one to
            // an extension-less name, and the picker matches it here so
            // the two requests read alike.
            inner.pickFile(onResult: picked)
        }
        tx.button("save") { _ in  // button#1
            // SAVE-BACK NEEDS NO DIALOG. The user already chose this
            // file, and the handle they chose it with is writable — the
            // claim this step exists to drive.
            guard let file = source else {
                fatalError("kaya: the scene opens a file before saving")
            }
            work { "saved \(writeBack(file, "second draft"))" }
        }
        tx.button("save as") { inner in  // button#2
            // The suggested name the dialog OPENS with; the harness
            // types over it, which is what a save dialog is for.
            inner.saveFile(suggestedName: "copy", onResult: saved)
        }
        tx.button("reopen") { _ in  // button#3
            // BOTH, in order: the file that was opened must still hold
            // the save-back, and the destination must hold the save-as.
            // A save that went to the wrong handle passes every earlier
            // step and fails here.
            guard let first = source, let second = destination else {
                fatalError("kaya: the scene opens a file and saves as before reopening")
            }
            work { "reopened \(readBack(first)) \(readBack(second))" }
        }
    }
    tx.mount(root)
}

app.run()
