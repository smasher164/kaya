// The filedialog scene, Swift port — guests/rust/filedialog.rs,
// tools/scenes/filedialog.steps.

import Foundation
import Kaya

KayaApp.run { app in
    let post = app.post
    // NOT THE TEMP DIRECTORY ON iOS: $TMP there is the app's own Documents
    // (kayaTempDir in swift/KayaSwiftUI.swift) — the picker browses PROVIDERS and
    // cannot see private storage. TMPDIR elsewhere; NSTemporaryDirectory() ignores
    // it (docs/traps.md).
    #if os(iOS)
        let kayaTmp = (NSHomeDirectory() as NSString).appendingPathComponent("Documents")
    #else
        let kayaTmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
    #endif
    let pickedDir = (kayaTmp as NSString)
        .appendingPathComponent("kaya-picked-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(
        atPath: pickedDir, withIntermediateDirectories: true)
    // THE DECOY MATTERS: with one file in the directory, pressing Open with
    // nothing selected returns it (docs/traps.md).
    try? "picked bytes".write(
        toFile: (pickedDir as NSString).appendingPathComponent("picked.txt"),
        atomically: true, encoding: .utf8)
    try? "decoy".write(
        toFile: (pickedDir as NSString).appendingPathComponent("decoy.txt"),
        atomically: true, encoding: .utf8)

    let released = DispatchSemaphore(value: 0)

    app.build { tx in
        tx.window(title: "filedialog")
        let status = tx.signal(.str("no file"))
        let receive: @KayaAppActor @Sendable (KayaAppTx, String) -> Void = { tx, text in
            tx.write(status, .str(text))
        }

        func picked(_ tx: KayaAppTx, _ files: [KayaPickedFile]) throws {
            if files.isEmpty {
                // The empty list IS cancel.
                tx.write(status, .str("cancelled"))
                return
            }
            Thread.detachNewThread {
                var text = ""
                do {
                    let (file, _) = try files[0].open()
                    let data = file.readDataToEndOfFile()
                    text = String(decoding: data, as: UTF8.self)
                    try? file.close()
                } catch {
                    text = "open failed: \(error)"
                }
                // Parks holding the result, standing in for a slow transfer's tail.
                released.wait()
                let count = files.count
                let read = text
                post { tx in
                    receive(tx, "\(count) \(read)")
                }
            }
            // The handler RETURNED without reading.
            tx.write(status, .str("reading"))
        }

        let root = tx.column { root in
            tx.setA11yId(tx.label(bind: status), "status")  // label#0
            tx.button(
                "open",
                onClick: { inner in  // button#0
                    // Filters are ADVISORY: a default view, never a guarantee.
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
            return root
        }
        tx.mount(root)
    }
}
