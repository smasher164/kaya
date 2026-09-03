// The drag-and-drop scene, Swift port — guests/rust/dnd.rs,
// tools/scenes/dnd.steps. THE ROOT IS A ROW so column#0 is the
// reorderable For's container.

import Foundation

struct Item: KayaGen {
    var title: String
}

let app = KayaApp()
let noteID = "dev.kaya/note"

func word(_ op: KayaOp?) -> String {
    switch op {
    case .copy: return "copy"
    case .move: return "move"
    case nil: return "none"
    }
}

app.build { tx in
    let items = itemCollection(tx)
    let dropStatus = tx.signal(.str("no drop yet"))
    let dragStatus = tx.signal(.str("no drag yet"))
    let sourceText = tx.signal(.str("hello"))
    let textTarget = tx.signal(.str("text target"))
    let noteTarget = tx.signal(.str("note target"))
    let filesTarget = tx.signal(.str("files target"))

    var source = KayaWidget(id: 0)
    var textID = KayaWidget(id: 0)
    var noteWidget = KayaWidget(id: 0)
    var list = KayaWidget(id: 0)
    let root = tx.row {
        list = itemEach(tx, items) { row in
            row.t.setA11yId(row.label(row.title), "row")
        }
        tx.column {
            source = tx.label(bind: sourceText)  // label#0
            textID = tx.label(bind: textTarget)  // label#1
            tx.setAccepts(textID, [KayaAppTx.acceptText])
            tx.setDropTarget(textID, [.copy])
            noteWidget = tx.label(bind: noteTarget)  // label#2
            tx.setAccepts(noteWidget, [noteID])
            tx.setDropTarget(noteWidget, [.copy, .move])
            let filesID = tx.label(bind: filesTarget)  // label#3
            tx.setAccepts(filesID, [KayaAppTx.acceptFiles])
            tx.setDropTarget(filesID, [.copy])
            _ = tx.label(bind: dropStatus)  // label#4
            _ = tx.label(bind: dragStatus)  // label#5
        }
    }
    tx.mount(root)
    tx.draggable(source)
        .text("hello")
        .custom(noteID, Array("note!".utf8))
        .allow(.copy)
        .allow(.move)
        .declare()
    tx.setReorderable(list, true)

    func dropped(_ name: String, _ target: KayaSignal)
        -> (KayaAppTx, KayaDropped) throws -> Void
    {
        { tx, d in
            let op = word(d.operation)
            switch d.clip {
            case .text(let text):
                tx.write(dropStatus, .str("\(name) got text \(text) (\(op))"))
                tx.write(target, .str(text))
            case .custom(let id, let bytes):
                tx.write(dropStatus, .str("\(name) got \(id) \(bytes.count) bytes (\(op))"))
            default:
                tx.write(dropStatus, .str("\(name) got other (\(op))"))
            }
            // A same-app MOVE removes its original in the same batch (D2).
            if d.operation == .move {
                tx.write(sourceText, .str("moved out"))
                tx.draggable(source).declare()
            }
        }
    }
    tx.onDrop(textID, dropped("text target", textTarget))
    tx.onDrop(noteWidget, dropped("note target", noteTarget))
    tx.onDragEnded(source) { tx, op in
        tx.write(dragStatus, .str("drag ended \(word(op))"))
    }
    // The moved row's key rides as the kaya-private custom
    // representation; the anchor is the row it landed on (D8).
    tx.onDrop(list) { tx, d in
        guard case .custom(_, let bytes) = d.clip,
            case .str(let anchor)? = d.anchor.first
        else { return }
        let moved = String(decoding: bytes, as: UTF8.self)
        if d.before {
            items.moveBefore(tx, .str(moved), .str(anchor))
        } else {
            items.moveAfter(tx, .str(moved), .str(anchor))
        }
    }

    for key in ["a", "b", "c"] {
        items.insert(tx, .str(key), Item(title: key))
    }
}

app.run()
