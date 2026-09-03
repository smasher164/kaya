// DragProbe SOURCE (macOS) — docs/dnd-plan.md §2 probe 3.
//
// Writes kaya's MIME-shaped custom id (`dev.kaya/note`) onto the DRAG
// pasteboard by every route an AppKit or SwiftUI drag source can take, and
// prints what each route actually put there. A reverse-DNS control id
// (`dev.kaya.note`) rides along in every route, because the report probe 3
// is about blames a missing UTExportedTypeDeclarations — a declaration only
// a reverse-DNS identifier can legally carry.
//
// One route per run (argv[1]); the receiver process reads the board after.
// THROWAWAY; nothing builds it but run.py beside it.
import AppKit
import UniformTypeIdentifiers

let mimeID = "dev.kaya/note"
let rdnsID = "dev.kaya.note"
let mimeBytes = Data("note=1".utf8)
let rdnsBytes = Data("rdns=1".utf8)
let plainText = "note text"

func say(_ s: String) {
    print("SRC \(s)")
    fflush(stdout)
}

// A route that wedges must not take the probe with it (no run loop is
// pumped here, but beginDraggingSession is AppKit's own code).
let watchdog = Thread {
    Thread.sleep(forTimeInterval: 20)
    FileHandle.standardError.write(Data("SRC WATCHDOG fired at 20s\n".utf8))
    exit(9)
}
watchdog.start()

let route = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "board"
let bundleID = Bundle.main.bundleIdentifier ?? "<none>"
say("==== route=\(route) bundle=\(bundleID) macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

// Does the SYSTEM know either id as a type? A declared UTI resolves here;
// a MIME-shaped string cannot be a UTI at all. This is the plist claim,
// measured rather than argued.
for id in [mimeID, rdnsID, "public.utf8-plain-text"] {
    let t = UTType(id)
    say("UTType(\"\(id)\") = \(t.map { "\($0.identifier) declared=\($0.isDeclared) dynamic=\($0.isDynamic)" } ?? "<nil>")")
}
// THE PLIST'S ACTUAL MECHANISM: an exported declaration maps a MIME TAG
// onto a reverse-DNS identifier. If a declaration is what makes a
// MIME-shaped id work, this is where it would show.
say("UTType(mimeType: \"\(mimeID)\") = \(UTType(mimeType: mimeID)?.identifier ?? "<nil>")")
say("UTType(tag: \"\(mimeID)\", .mimeType) = "
    + "\(UTType(tag: mimeID, tagClass: .mimeType, conformingTo: nil)?.identifier ?? "<nil>")")
say("UTType(\"\(rdnsID)\").tags = \(UTType(rdnsID)?.tags ?? [:])")

let board = NSPasteboard(name: .drag)

/// What is on the drag board right now, from the writer's own side.
func report(_ label: String) {
    say("\(label) board.changeCount=\(board.changeCount)")
    say("\(label) board.types=\(board.types?.map(\.rawValue) ?? [])")
    for id in [mimeID, rdnsID, NSPasteboard.PasteboardType.string.rawValue] {
        let d = board.data(forType: NSPasteboard.PasteboardType(id))
        say("\(label) data[\(id)] = \(d.map { "\($0.count) bytes \(String(decoding: $0, as: UTF8.self))" } ?? "<nil>")")
    }
    say("\(label) items=\(board.pasteboardItems?.count ?? -1)")
    for (i, item) in (board.pasteboardItems ?? []).enumerated() {
        say("\(label) item[\(i)].types=\(item.types.map(\.rawValue))")
    }
}

/// Route 3's writer: an NSPasteboardWriting of our own, which is the one
/// way an AppKit drag source can name a type string without going through
/// NSPasteboardItem's UTI validation — if AppKit does not validate here too.
final class KayaWriter: NSObject, NSPasteboardWriting {
    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.init(mimeID), .init(rdnsID), .string]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type.rawValue {
        case mimeID: return mimeBytes
        case rdnsID: return rdnsBytes
        default: return plainText
        }
    }

    func writingOptions(forType type: NSPasteboard.PasteboardType,
                        pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        []
    }
}

/// Route 5's source; the session needs one.
final class DragSource: NSObject, NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move]
    }
}

switch route {

// ---- 1. the BOARD-level path, which is kaya's copy arm's own -----------
case "board":
    board.clearContents()
    let stamp = board.declareTypes([.init(mimeID), .init(rdnsID), .string], owner: nil)
    let a = board.setData(mimeBytes, forType: .init(mimeID))
    let b = board.setData(rdnsBytes, forType: .init(rdnsID))
    let c = board.setString(plainText, forType: .string)
    say("board declareTypes=\(stamp) setData(mime)=\(a) setData(rdns)=\(b) setString=\(c)")
    report("board")

// ---- 2. NSPasteboardItem, which is what a drag source hands over -------
case "item":
    board.clearContents()
    let item = NSPasteboardItem()
    let a = item.setData(mimeBytes, forType: .init(mimeID))
    let b = item.setData(rdnsBytes, forType: .init(rdnsID))
    let c = item.setString(plainText, forType: .string)
    say("item setData(mime)=\(a) setData(rdns)=\(b) setString=\(c)")
    say("item.types (before write) = \(item.types.map(\.rawValue))")
    let ok = board.writeObjects([item])
    say("item writeObjects=\(ok)")
    report("item")

// ---- 3. a hand-written NSPasteboardWriting -----------------------------
case "writer":
    board.clearContents()
    let w = KayaWriter()
    say("writer writableTypes=\(w.writableTypes(for: board).map(\.rawValue))")
    let ok = board.writeObjects([w])
    say("writer writeObjects=\(ok)")
    report("writer")

// ---- 4. NSItemProvider, which is SwiftUI's .onDrag currency ------------
case "provider":
    let p = NSItemProvider()
    p.registerDataRepresentation(forTypeIdentifier: mimeID, visibility: .all) { done in
        done(mimeBytes, nil); return nil
    }
    p.registerDataRepresentation(forTypeIdentifier: rdnsID, visibility: .all) { done in
        done(rdnsBytes, nil); return nil
    }
    p.registerDataRepresentation(forTypeIdentifier: "public.utf8-plain-text",
                                 visibility: .all) { done in
        done(Data(plainText.utf8), nil); return nil
    }
    say("provider registeredTypeIdentifiers=\(p.registeredTypeIdentifiers)")
    say("provider hasItemConformingToTypeIdentifier(mime)=\(p.hasItemConformingToTypeIdentifier(mimeID))")
    // Does the provider hand the bytes back in process? (SwiftUI's own
    // destination reads them this way.)
    for id in [mimeID, rdnsID] {
        let sem = DispatchSemaphore(value: 0)
        var got = "<no callback>"
        p.loadDataRepresentation(forTypeIdentifier: id) { data, err in
            got = data.map { "\($0.count) bytes \(String(decoding: $0, as: UTF8.self))" }
                ?? "<nil> err=\(err.map { "\($0)" } ?? "<none>")"
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 3)
        say("provider loadDataRepresentation(\(id)) -> \(got)")
    }
    // THE BRIDGE: is a provider even writable to a pasteboard on macOS?
    // Measured, not assumed — SwiftUI's onDrag goes through some route and
    // the public one is NSPasteboardWriting.
    say("provider is NSPasteboardWriting = \(p is NSPasteboardWriting)")
    board.clearContents()
    if let w = p as? NSPasteboardWriting {
        say("provider writableTypes=\(w.writableTypes(for: board).map(\.rawValue))")
        let ok = board.writeObjects([w])
        say("provider writeObjects=\(ok)")
    } else {
        // Fall back to the documented conversion an AppKit source would do.
        say("provider not writable directly; writing NSPasteboardItem from its bytes")
        let item = NSPasteboardItem()
        _ = item.setData(mimeBytes, forType: .init(mimeID))
        _ = item.setData(rdnsBytes, forType: .init(rdnsID))
        _ = item.setString(plainText, forType: .string)
        say("fallback item writeObjects=\(board.writeObjects([item]))")
    }
    report("provider")

// ---- 5. THE REAL THING, minus the pointer ------------------------------
//
// beginDraggingSession is what AppKit itself uses to fill the drag board.
// No CGEvent is posted (the repo refuses it): the NSEvent is CONSTRUCTED,
// not delivered, and the session is read and torn down immediately. What is
// measured is the board AppKit composed, not a gesture.
case "session", "session-writer":
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    window.contentView = view
    window.orderBack(nil)

    // ONE SESSION PER PROCESS: a second beginDraggingSession while the
    // first is in flight answers a session with an EMPTY pasteboard and
    // sequence 0, which would look like a finding and is not.
    let which: [(String, NSPasteboardWriting)] =
        route == "session" ? [("item", NSPasteboardItem())] : [("writer", KayaWriter())]
    for (label, writer) in which {
        if let item = writer as? NSPasteboardItem {
            _ = item.setData(mimeBytes, forType: .init(mimeID))
            _ = item.setData(rdnsBytes, forType: .init(rdnsID))
            _ = item.setString(plainText, forType: .string)
        }
        let di = NSDraggingItem(pasteboardWriter: writer)
        di.setDraggingFrame(NSRect(x: 0, y: 0, width: 10, height: 10),
                            contents: NSImage(size: NSSize(width: 10, height: 10)))
        guard let ev = NSEvent.mouseEvent(with: .leftMouseDown,
                                          location: NSPoint(x: 100, y: 100),
                                          modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber,
                                          context: nil,
                                          eventNumber: 0,
                                          clickCount: 1,
                                          pressure: 1)
        else { say("session[\(label)] could not construct an NSEvent"); continue }
        let session = view.beginDraggingSession(with: [di], event: ev, source: DragSource())
        let pb = session.draggingPasteboard
        say("session[\(label)] pasteboard.name=\(pb.name.rawValue)")
        say("session[\(label)] types=\(pb.types?.map(\.rawValue) ?? [])")
        for id in [mimeID, rdnsID, NSPasteboard.PasteboardType.string.rawValue] {
            let d = pb.data(forType: .init(id))
            say("session[\(label)] data[\(id)] = \(d.map { "\($0.count) bytes \(String(decoding: $0, as: UTF8.self))" } ?? "<nil>")")
        }
        say("session[\(label)] sequence=\(session.draggingSequenceNumber)")
    }
    report("session-after")

// ---- 6. THE WORKAROUND THE ARM WOULD NEED --------------------------
//
// If the ITEM path drops a slashed type and the BOARD path keeps it, can a
// real session be started and the custom type then ADDED at board level,
// onto the board AppKit itself composed?
case "session-board":
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    window.contentView = view
    window.orderBack(nil)

    let item = NSPasteboardItem()
    _ = item.setData(rdnsBytes, forType: .init(rdnsID))
    _ = item.setString(plainText, forType: .string)
    let di = NSDraggingItem(pasteboardWriter: item)
    di.setDraggingFrame(NSRect(x: 0, y: 0, width: 10, height: 10),
                        contents: NSImage(size: NSSize(width: 10, height: 10)))
    guard let ev = NSEvent.mouseEvent(with: .leftMouseDown,
                                      location: NSPoint(x: 100, y: 100),
                                      modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber,
                                      context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 1)
    else { say("session-board could not construct an NSEvent"); exit(2) }
    let session = view.beginDraggingSession(with: [di], event: ev, source: DragSource())
    let pb = session.draggingPasteboard
    say("session-board before types=\(pb.types?.map(\.rawValue) ?? [])")
    // addTypes, NOT clearContents: the session's own data must survive.
    let stamp = pb.addTypes([.init(mimeID)], owner: nil)
    let ok = pb.setData(mimeBytes, forType: .init(mimeID))
    say("session-board addTypes=\(stamp) setData(mime)=\(ok)")
    say("session-board after types=\(pb.types?.map(\.rawValue) ?? [])")
    for id in [mimeID, rdnsID, NSPasteboard.PasteboardType.string.rawValue] {
        let d = pb.data(forType: .init(id))
        say("session-board data[\(id)] = \(d.map { "\($0.count) bytes \(String(decoding: $0, as: UTF8.self))" } ?? "<nil>")")
    }
    say("session-board items=\(pb.pasteboardItems?.count ?? -1)")
    for (i, it) in (pb.pasteboardItems ?? []).enumerated() {
        say("session-board item[\(i)].types=\(it.types.map(\.rawValue))")
    }
    report("session-board-drag")

// ---- 0. HYGIENE: hand the system drag board back ------------------
//
// Every route above writes a SYSTEM pasteboard. This is what the probe
// runs last so it leaves nothing of its own on it.
case "clear":
    board.clearContents()
    say("clear board.changeCount=\(board.changeCount) types=\(board.types?.map(\.rawValue) ?? [])")

default:
    say("unknown route \(route)")
    exit(2)
}

say("==== end route=\(route)")
exit(0)
