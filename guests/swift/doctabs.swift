// The document-tabs scene, Swift port — guests/rust/doctabs.rs,
// tools/scenes/doctabs.steps (docs/doctabs-plan.md §5): three documents, one
// armed against a close, a shared region beside them, the "+", and a
// programmatic select that echoes nothing.

import Foundation
import Kaya

let docA: UInt64 = 10
let docB: UInt64 = 11
let docC: UInt64 = 12
let notesRegion: UInt64 = 30
let names: [(UInt64, String)] = [(docA, "a"), (docB, "b"), (docC, "c")]

KayaApp.run { app in
    var untitled: UInt64 = 0
    var regions: UInt64 = 0
    app.build { tx in
        let status = tx.signal(.str("ready"))

        // THE ONE BUILDER every window's shared region comes from, the first
        // window's and a torn-out one's alike (docs/doctabs-plan.md §1.2).
        func region(_ tx: KayaAppTx, _ window: UInt64, _ id: UInt64) {
            tx.addRegion(id, .leading, window: window)
            let root = tx.column { root in
                tx.setA11yId(tx.label(bind: status), "status")
                tx.setA11yId(tx.entry(), "note")
                tx.setA11yId(tx.button("to a") { tx in tx.selectDocument(docA) }, "first")
                return root
            }
            tx.mountIn(id, root)
        }

        tx.window(
            title: "doctabs", width: 640, height: 420, newDocument: true,
            onNewDocument: { tx in
                untitled += 1
                let name = "untitled \(untitled)"
                let id = 100 + untitled
                tx.addDocument(id, title: name)
                tx.selectDocument(id)
                let caption = tx.signal(.str("\(name) body"))
                tx.mountIn(id, tx.column { root in
                    tx.label(bind: caption)
                    return root
                })
                tx.write(status, .str("new \(name)"))
            },
            onDocumentsCloseRequested: { tx, documents in
                tx.write(status, .str("asked about \(documents.count)"))
            },
            onDocumentsDetached: { tx, window, documents in
                regions += 1
                region(tx, window, 300 + regions)
                let moved = documents.map { d in names.first { $0.0 == d }?.1 ?? "untitled" }
                tx.write(status, .str("detached \(moved.joined(separator: " "))"))
            })

        for (id, name) in names {
            tx.addDocument(
                id, title: name, tooltip: "/documents/\(name)",
                interceptClose: id == docB ? true : nil,
                onSelected: { tx in tx.write(status, .str("selected \(name)")) },
                onCloseRequested: id == docB
                    ? { tx in
                        tx.showAlert(
                            title: "unsaved changes", message: "b has unsaved changes",
                            actions: ["Discard"], cancel: "Keep Editing"
                        ) { tx, choice in
                            if choice == .cancel {
                                tx.write(status, .str("kept b"))
                                return
                            }
                            tx.closeDocument(docB)
                            tx.write(status, .str("discarded b"))
                        }
                    } : nil,
                onClosed: { tx in tx.write(status, .str("closed \(name)")) },
                onMoved: { tx, _, index in tx.write(status, .str("moved \(name) to \(index)")) })
            let caption = tx.signal(.str("\(name) body"))
            tx.mountIn(id, tx.column { root in
                tx.setA11yId(tx.label(bind: caption), "body-\(name)")
                tx.setA11yId(tx.entry(), "field-\(name)")
                if id == docB {
                    tx.setA11yId(tx.button("mark b") { tx in
                        tx.updateDocument(docB, dirty: true)
                        tx.write(status, .str("marked b"))
                    }, "mark")
                }
                return root
            })
        }
        region(tx, 0, notesRegion)
    }
}
