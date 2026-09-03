// DragProbe RECEIVER (macOS) — docs/dnd-plan.md §2 probe 3 and D10's mac route.
//
// A SEPARATE PROCESS from src.swift. Two halves:
//
//  (a) CROSS-PROCESS: read NSPasteboard(name: .drag) — the board the source
//      process wrote and exited — and say what arrived. This is the honest
//      answer to "does the custom id cross a process boundary", with the
//      gesture stated as not driven.
//  (b) IN PROCESS (D10): the REAL NSDraggingDestination arms of a REAL view
//      registered for the custom types, driven through an NSDraggingInfo
//      DOUBLE over that same real pasteboard. NSDraggingInfo is a protocol,
//      which is the whole reason D7 puts the mac destination on an AppKit
//      view instead of a SwiftUI DropDelegate.
//
// THROWAWAY; nothing builds it but run.py beside it.
import AppKit
import UniformTypeIdentifiers

let mimeID = "dev.kaya/note"
let rdnsID = "dev.kaya.note"

func say(_ s: String) {
    print("RCV \(s)")
    fflush(stdout)
}

let watchdog = Thread {
    Thread.sleep(forTimeInterval: 20)
    FileHandle.standardError.write(Data("RCV WATCHDOG fired at 20s\n".utf8))
    exit(9)
}
watchdog.start()

// ---- the destination, an AppKit view (D7) ------------------------------

final class KayaDest: NSView {
    var log: [String] = []

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        log.append("draggingEntered types=\(pb.types?.map(\.rawValue) ?? [])")
        log.append("draggingEntered sourceMask=\(maskName(sender.draggingSourceOperationMask))")
        log.append("draggingEntered location=\(sender.draggingLocation)")
        // The hover verdict, answered from the TYPES alone (§0's rule).
        let offered = Set(pb.types?.map(\.rawValue) ?? [])
        let wanted = [mimeID, rdnsID, NSPasteboard.PasteboardType.string.rawValue]
        let hit = wanted.first { offered.contains($0) }
        log.append("draggingEntered accepts-because=\(hit ?? "<nothing offered matched>")")
        return hit == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        log.append("draggingUpdated mask=\(maskName(sender.draggingSourceOperationMask))")
        return .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        log.append("prepareForDragOperation")
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        log.append("performDragOperation types=\(pb.types?.map(\.rawValue) ?? [])")
        for id in [mimeID, rdnsID, NSPasteboard.PasteboardType.string.rawValue] {
            let d = pb.data(forType: .init(id))
            log.append("performDragOperation data[\(id)] = "
                + (d.map { "\($0.count) bytes \(String(decoding: $0, as: UTF8.self))" } ?? "<nil>"))
        }
        // What the classes-based reader enumerates, which is what a
        // SwiftUI/NSItemProvider destination would see.
        let items = pb.readObjects(forClasses: [NSPasteboardItem.self], options: nil) as? [NSPasteboardItem] ?? []
        log.append("performDragOperation readObjects(NSPasteboardItem) count=\(items.count) "
            + "types=\(items.map { $0.types.map(\.rawValue) })")
        return true
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        log.append("draggingExited")
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        log.append("concludeDragOperation")
    }
}

func maskName(_ m: NSDragOperation) -> String {
    var parts: [String] = []
    if m.contains(.copy) { parts.append("copy") }
    if m.contains(.move) { parts.append("move") }
    if m.contains(.link) { parts.append("link") }
    if m.contains(.generic) { parts.append("generic") }
    if m.contains(.delete) { parts.append("delete") }
    if m.isEmpty { parts.append("none") }
    return "\(parts.joined(separator: "|")) (raw \(m.rawValue))"
}

// ---- the NSDraggingInfo double (D10) -----------------------------------

final class InfoDouble: NSObject, NSDraggingInfo {
    let board: NSPasteboard
    var mask: NSDragOperation
    init(board: NSPasteboard, mask: NSDragOperation) {
        self.board = board
        self.mask = mask
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { mask }
    var draggingLocation: NSPoint { NSPoint(x: 42, y: 17) }
    var draggedImageLocation: NSPoint { NSPoint(x: 42, y: 17) }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { board }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var numberOfValidItemsForDrop: Int = 1
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination: Bool = false
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions,
                                for view: NSView?,
                                classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

// ---- the run ------------------------------------------------------------

let bundleID = Bundle.main.bundleIdentifier ?? "<none>"
say("==== bundle=\(bundleID)")
for id in [mimeID, rdnsID] {
    let t = UTType(id)
    say("UTType(\"\(id)\") = \(t.map { "\($0.identifier) declared=\($0.isDeclared) dynamic=\($0.isDynamic)" } ?? "<nil>")")
}
say("UTType(mimeType: \"\(mimeID)\") = \(UTType(mimeType: mimeID)?.identifier ?? "<nil>")")

// What does AppKit KEEP when a view registers for a MIME-shaped type?
let dest = KayaDest(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
dest.registerForDraggedTypes([.init(mimeID), .init(rdnsID), .string])
say("registeredDraggedTypes=\(dest.registeredDraggedTypes.map(\.rawValue))")

// (a) cross-process read of the drag board the source process wrote.
let drag = NSPasteboard(name: .drag)
say("drag board changeCount=\(drag.changeCount)")
say("drag board types=\(drag.types?.map(\.rawValue) ?? [])")
say("drag board items=\(drag.pasteboardItems?.count ?? -1)")
for (i, item) in (drag.pasteboardItems ?? []).enumerated() {
    say("drag board item[\(i)].types=\(item.types.map(\.rawValue))")
}
for id in [mimeID, rdnsID, NSPasteboard.PasteboardType.string.rawValue] {
    let d = drag.data(forType: .init(id))
    say("drag board data[\(id)] = "
        + (d.map { "\($0.count) bytes \(String(decoding: $0, as: UTF8.self))" } ?? "<nil>"))
}
for t in (drag.types ?? []) {
    let u = UTType(t.rawValue)
    say("drag board type \(t.rawValue) -> UTType "
        + (u.map { "\($0.identifier) dynamic=\($0.isDynamic) mime=\($0.preferredMIMEType ?? "<none>") tags=\($0.tags)" }
            ?? "<nil, not a UTI>"))
}
say("drag board canReadItem(mime)="
    + "\(drag.canReadItem(withDataConformingToTypes: [mimeID]))")
say("drag board availableType(mime,rdns,string)="
    + "\(drag.availableType(from: [.init(mimeID), .init(rdnsID), .string])?.rawValue ?? "<nil>")")

// (b) the real destination arms, over that real board.
let info = InfoDouble(board: drag, mask: [.copy, .move])
let entered = dest.draggingEntered(info)
let updated = dest.draggingUpdated(info)
let prepared = dest.prepareForDragOperation(info)
let performed = dest.performDragOperation(info)
dest.concludeDragOperation(info)
for line in dest.log { say("arm \(line)") }
say("arm RESULT entered=\(maskName(entered)) updated=\(maskName(updated)) "
    + "prepared=\(prepared) performed=\(performed)")

// (c) D10 WITHOUT TOUCHING THE SYSTEM DRAG BOARD: the same double over a
// PRIVATE named pasteboard, which is what a mac gate should use — a gate
// that writes NSPasteboard(name: .drag) would stamp on a drag the person
// at the machine is in the middle of.
let scratch = NSPasteboard(name: .init("dev.kaya.dragprobe.scratch"))
scratch.clearContents()
_ = scratch.declareTypes([.init(mimeID), .string], owner: nil)
_ = scratch.setData(Data("scratch=1".utf8), forType: .init(mimeID))
_ = scratch.setString("scratch text", forType: .string)
let dest2 = KayaDest(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
dest2.registerForDraggedTypes([.init(mimeID), .string])
let info2 = InfoDouble(board: scratch, mask: [.copy])
let e2 = dest2.draggingEntered(info2)
let p2 = dest2.performDragOperation(info2)
for line in dest2.log { say("scratch \(line)") }
say("scratch RESULT entered=\(maskName(e2)) performed=\(p2)")
scratch.releaseGlobally()

say("==== end")
exit(0)
