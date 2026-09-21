// The save scene, Swift port — guests/rust/save.rs, tools/scenes/save.steps.

import Foundation
import Kaya

KayaApp.run { app in
    let post = app.post
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

    // Handles, never paths — `localPath` is nil on both phones.
    var source: KayaPickedFile?
    var destination: KayaPickedFile?

    /// Read a handle back through kaya, with Foundation's own file API.
    @Sendable func readBack(_ file: KayaPickedFile) -> String {
        do {
            let (handle, _) = try file.open(.read)
            let data = handle.readDataToEndOfFile()
            try? handle.close()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return "open failed: \(error)"
        }
    }

    /// Write `text` through a handle and report what the FILE says afterwards.
    /// `.write` truncates; a destination adds create.
    @Sendable func writeBack(_ file: KayaPickedFile, _ text: String) -> String {
        do {
            let (handle, _) = try file.open(.write)
            handle.write(Data(text.utf8))
            // Closed before the reopen, so what comes back is the FILE's bytes.
            try? handle.close()
            return readBack(file)
        } catch {
            // Without the create, a save destination answers ENOENT here (D1).
            return "save failed: \(error)"
        }
    }

    app.build { tx in
        tx.window(title: "save")
        let status = tx.signal(.str("no file"))
        let receive: @KayaAppActor @Sendable (KayaAppTx, String) -> Void = { tx, text in
            tx.write(status, .str(text))
        }
        func work(_ job: @escaping @Sendable () -> String) {
            Thread.detachNewThread {
                let text = job()
                post { tx in receive(tx, text) }
            }
        }

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

        let root = tx.column { root in
            tx.setA11yId(tx.label(bind: status), "status")  // label#0
            tx.button("open") { _ in
                app.task {
                    let files = await app.pickFile()
                    app.build { tx in picked(tx, files) }
                }
            }
            tx.button("save") { tx in
                guard let file = source else {
                    tx.write(status, .str("nothing open to save"))
                    return
                }
                work { "saved \(writeBack(file, "second draft"))" }
            }
            tx.button("save as") { _ in
                app.task {
                    let file = await app.saveFile(suggestedName: "copy")
                    app.build { tx in saved(tx, file) }
                }
            }
            tx.button("reopen") { tx in
                guard let first = source, let second = destination else {
                    tx.write(status, .str("nothing to reopen"))
                    return
                }
                work { "reopened \(readBack(first)) \(readBack(second))" }
            }
            return root
        }
        tx.mount(root)
    }
}
