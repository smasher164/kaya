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

func keyWord(_ keys: [KayaValue]) -> String {
    if case .str(let s)? = keys.first { return s }
    return ""
}

// The file the scene drops as a FOREIGN source (D6), written by the guest
// at $TMP/kaya-dnd-$PID/dropped.txt — the picker and clipboard scenes'
// convention. NSTemporaryDirectory() ignores TMPDIR (docs/traps.md); on
// iOS $TMP is the app's own Documents (kayaTempDir in KayaSwiftUI.swift).
#if os(iOS)
    let kayaTmp = (NSHomeDirectory() as NSString).appendingPathComponent("Documents")
#else
    let kayaTmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
#endif
let droppedDir = (kayaTmp as NSString)
    .appendingPathComponent("kaya-dnd-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(
    atPath: droppedDir, withIntermediateDirectories: true)
try? "dropped bytes".write(
    toFile: (droppedDir as NSString).appendingPathComponent("dropped.txt"),
    atomically: true, encoding: .utf8)

func readBack(_ file: KayaPickedFile) -> String {
    do {
        let (handle, _) = try file.open()
        let data = handle.readDataToEndOfFile()
        try? handle.close()
        return String(decoding: data, as: UTF8.self)
    } catch {
        return "open failed: \(error)"
    }
}

app.build { tx in
    let items = itemCollection(tx)
    let items2 = itemCollection(tx)
    let dropStatus = tx.signal(.str("no drop yet"))
    let dragStatus = tx.signal(.str("no drag yet"))
    let sourceText = tx.signal(.str("hello"))
    let textTarget = tx.signal(.str("text target"))
    let noteTarget = tx.signal(.str("note target"))
    let filesTarget = tx.signal(.str("files target"))

    var source = KayaWidget(id: 0)
    var textID = KayaWidget(id: 0)
    var noteWidget = KayaWidget(id: 0)
    var filesWidget = KayaWidget(id: 0)
    var list = KayaWidget(id: 0)
    var rowLabel = KayaNodeHandle(id: 0)
    var itemLabel = KayaNodeHandle(id: 0)
    let root = tx.row {
        list = itemEach(tx, items) { row in
            rowLabel = row.label(row.title)
            row.t.setA11yId(rowLabel, "row")
        }
        tx.setA11yId(list, "rows")
        tx.column {
            source = tx.label(bind: sourceText)  // label#0
            textID = tx.label(bind: textTarget)  // label#1
            tx.setAccepts(textID, [KayaAppTx.acceptText])
            tx.setDropTarget(textID, [.copy])
            noteWidget = tx.label(bind: noteTarget)  // label#2
            tx.setAccepts(noteWidget, [noteID])
            tx.setDropTarget(noteWidget, [.copy, .move])
            filesWidget = tx.label(bind: filesTarget)  // label#3
            tx.setAccepts(filesWidget, [KayaAppTx.acceptFiles])
            tx.setDropTarget(filesWidget, [.copy])
            _ = tx.label(bind: dropStatus)  // label#4
            _ = tx.label(bind: dragStatus)  // label#5
        }
        // THE TEMPLATE ZONE (docs/dnd-plan.md §4): every stamped item is a
        // text destination, and its payload IS the row's own field —
        // resolved per copy, re-declared when the field changes — column#2.
        let itemList = itemEach(tx, items2) { row in
            itemLabel = row.label(row.title)
            row.t.setA11yId(itemLabel, "item")
            row.t.setAccepts(itemLabel, [KayaAppTx.acceptText])
            row.t.setDropTarget(itemLabel, [.copy])
            row.t.draggable(itemLabel).text(row.title).allow(.copy).declare()
        }
        tx.setA11yId(itemList, "items")
        tx.button("rename y") { tx in  // button#0
            items2.update(tx, .str("y"), Item(title: "yy"))
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
            case .files(let files):
                // A dropped file IS a picked file (D6): read it back
                // through the same table the picker fills.
                let said = files.map { "\($0.name) \(readBack($0))" }
                    .joined(separator: ", ")
                tx.write(dropStatus, .str("\(name) got \(said) (\(op))"))
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
    tx.onDrop(filesWidget, dropped("files target", filesTarget))
    tx.onDragEnded(source) { tx, op in
        tx.write(dragStatus, .str("drag ended \(word(op))"))
    }
    tx.onDrop(itemLabel) { tx, keys, d in
        let op = word(d.operation)
        if case .text(let text) = d.clip {
            tx.write(dropStatus, .str("item \(keyWord(keys)) got text \(text) (\(op))"))
        } else {
            tx.write(dropStatus, .str("item \(keyWord(keys)) got other (\(op))"))
        }
    }
    func nodeEnded(_ what: String) -> (KayaAppTx, [KayaValue], KayaOp?) throws -> Void {
        { tx, keys, op in
            tx.write(dragStatus, .str("\(what) \(keyWord(keys)) drag ended \(word(op))"))
        }
    }
    tx.onDragEnded(itemLabel, nodeEnded("item"))
    tx.onDragEnded(rowLabel, nodeEnded("row"))
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
    for key in ["x", "y"] {
        items2.insert(tx, .str(key), Item(title: key))
    }
}

app.run()
