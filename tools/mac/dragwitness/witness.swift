// The mac FOREIGN DRAG WITNESS — docs/dnd-plan.md §5 step 7, D9.
//
// A process that is not kaya, on both ends of a REAL cross-process
// NSDraggingSession, plus the pointer driver that moves it. THREE MODES,
// each its own process, because a source that posts its own pointer events
// wedges inside AppKit's tracking loop (measured 2026-09-03, docs/traps.md).
//
//   witness catch --at x,y,w,h --report <path>
//       A window that is an NSDraggingDestination; writes what it received.
//
//   witness throw --at x,y,w,h [--file <path>] --report <path>
//       A window whose view starts a real NSDraggingSession on its first
//       mouseDragged, carrying kaya's own payload grammar (text, a
//       MIME-shaped custom id, a file URL). Writes the operation the
//       destination chose.
//
//   witness drive --press x,y --to x,y [--settle ms] [--report <path>]
//       The pointer, and nothing else: an activating click, a press, a walk
//       past AppKit's drag threshold, a walk to the target, a release.
//
// Screen points are CGEvent's: the origin is the TOP LEFT of the main
// display, where AppKit's is the bottom left.
//
// THE PAYLOAD IS WRITTEN AT BOARD LEVEL, the only route that keeps a
// MIME-shaped id on macOS (docs/probes/dnd-probe-mac-2026-09-03.md).
import AppKit

let mimeID = "dev.kaya/note"
let witnessText = "kaya-foreign-text"
let witnessNote = "foreign!"

func die(_ why: String) -> Never {
    FileHandle.standardError.write(Data("witness: \(why)\n".utf8))
    exit(2)
}

// ---- arguments ---------------------------------------------------------
var opts: [String: String] = [:]
var mode = ""
var args = Array(CommandLine.arguments.dropFirst())
if let first = args.first, !first.hasPrefix("--") {
    mode = first
    args.removeFirst()
}
while let flag = args.first {
    args.removeFirst()
    guard flag.hasPrefix("--"), let value = args.first else { die("stray \(flag)") }
    args.removeFirst()
    opts[String(flag.dropFirst(2))] = value
}
guard ["catch", "throw", "drive"].contains(mode) else {
    die("mode is catch, throw or drive")
}

func numbers(_ name: String, _ want: Int) -> [Double] {
    guard let raw = opts[name] else { die("--\(name) is required") }
    let parts = raw.split(separator: ",").compactMap { Double($0) }
    guard parts.count == want else { die("--\(name) wants \(want) numbers, got \(raw)") }
    return parts
}

let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0

// ---- the report --------------------------------------------------------
final class Report {
    private let path: String?
    private var lines: [String] = []
    private let lock = NSLock()
    init(path: String?) { self.path = path }
    func say(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
        print("WITNESS \(line)")
        fflush(stdout)
    }
    func write() {
        guard let path else { return }
        lock.lock()
        let text = lines.joined(separator: "\n") + "\n"
        lock.unlock()
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
if mode != "drive", opts["report"] == nil { die("--report is required") }
let report = Report(path: opts["report"])

// ---- the pointer -------------------------------------------------------
var lastPoint = CGPoint.zero
func post(_ type: CGEventType, _ p: CGPoint) {
    let source = CGEventSource(stateID: .hidSystemState)
    guard let event = CGEvent(
        mouseEventSource: source, mouseType: type, mouseCursorPosition: p,
        mouseButton: .left)
    else { return }
    // A MOVE WITH NO DELTA: AppKit's own tracking reads the delta fields,
    // and CGEvent leaves them zero.
    event.setIntegerValueField(.mouseEventDeltaX, value: Int64(p.x - lastPoint.x))
    event.setIntegerValueField(.mouseEventDeltaY, value: Int64(p.y - lastPoint.y))
    lastPoint = p
    event.post(tap: .cghidEventTap)
}

func walk(_ from: CGPoint, _ to: CGPoint, steps: Int, each: UInt32 = 16000) {
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        post(.leftMouseDragged,
             CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
        usleep(each)
    }
}

if mode == "drive" {
    let press = numbers("press", 2)
    let to = numbers("to", 2)
    let from = CGPoint(x: press[0], y: press[1])
    let target = CGPoint(x: to[0], y: to[1])
    let started = NSEvent.mouseLocation
    usleep(UInt32((opts["settle"].flatMap { Double($0) } ?? 600) * 1000))
    // THE ACTIVATING CLICK FIRST: AppKit does not deliver an inactive
    // window's first click to the view (`acceptsFirstMouse` is false), and a
    // press that starts a drag has to reach the view. Then past the
    // double-click interval, so the press that follows is a fresh one.
    post(.mouseMoved, from)
    usleep(120_000)
    post(.leftMouseDown, from)
    usleep(60_000)
    post(.leftMouseUp, from)
    usleep(700_000)
    post(.leftMouseDown, from)
    usleep(150_000)
    let past = CGPoint(x: from.x + 14, y: from.y + 14)
    walk(from, past, steps: 5)
    walk(past, target, steps: 30)
    // The destination is asked over and over; give its arms a few frames on
    // the point before the release chooses.
    for _ in 0..<8 {
        post(.leftMouseDragged, target)
        usleep(40_000)
    }
    post(.leftMouseUp, target)
    usleep(400_000)
    report.say("drove \(from) -> \(target)")
    report.write()
    CGWarpMouseCursorPosition(CGPoint(x: started.x, y: mainScreenHeight - started.y))
    exit(0)
}

// ---- the board modes ---------------------------------------------------
// A drag's payload IS a real system pasteboard, and a pasteboard has a name
// any process can open. These two modes are the cross-process byte exchange
// on its own, with no gesture in it: `throw --board <name>` composes kaya's
// payload grammar at BOARD level and exits, `catch --board <name>` opens the
// same board in a DIFFERENT process and says what it read.
func composeBoard(_ name: String, file: String?) {
    let board = NSPasteboard(name: .init(name))
    board.clearContents()
    var types: [NSPasteboard.PasteboardType] = [.init(mimeID), .string]
    if file != nil { types.append(.fileURL) }
    board.declareTypes(types, owner: nil)
    board.setData(Data(witnessNote.utf8), forType: .init(mimeID))
    board.setString(witnessText, forType: .string)
    if let file {
        board.setString(URL(fileURLWithPath: file).absoluteString, forType: .fileURL)
    }
    report.say("wrote \(name)")
}

func readBoard(_ name: String) {
    let board = NSPasteboard(name: .init(name))
    if let text = board.string(forType: .string) { report.say("text \(text)") }
    if let bytes = board.data(forType: .init(mimeID)) {
        report.say("custom \(mimeID) \(bytes.count) bytes")
    }
    let urls = (board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? [])
        .filter(\.isFileURL)
    for url in urls { report.say("file \(url.lastPathComponent)") }
}

if let name = opts["board"] {
    if mode == "throw" {
        composeBoard(name, file: opts["file"])
    } else {
        readBoard(name)
    }
    report.write()
    exit(0)
}

// ---- the destination half ---------------------------------------------
final class CatchView: NSView {
    var onDrop: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.string, .fileURL, .init(mimeID)])
    }
    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        report.say("entered local \(sender.draggingSource != nil)")
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        if let text = board.string(forType: .string) { report.say("text \(text)") }
        if let bytes = board.data(forType: .init(mimeID)) {
            report.say("custom \(mimeID) \(bytes.count) bytes")
        }
        let urls = (board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? [])
            .filter(\.isFileURL)
        for url in urls { report.say("file \(url.lastPathComponent)") }
        onDrop?()
        return true
    }
}

// ---- the source half ---------------------------------------------------
final class ThrowView: NSView, NSDraggingSource {
    var filePath: String?
    var onEnded: (() -> Void)?
    private var started = false

    // WITHOUT THIS THE DRAG SEQUENCE NEVER ARRIVES: NSResponder's default
    // mouseDown passes the press up the chain and every later mouseDragged
    // goes with it (measured 2026-09-03 — no session, an empty report).
    override func mouseDown(with event: NSEvent) {
        report.say("press at \(event.locationInWindow)")
    }

    override func mouseDragged(with event: NSEvent) {
        if started { return }
        started = true
        report.say("first drag at \(event.locationInWindow)")
        // The writer carries a type, as kaya's own source now does: an empty
        // NSPasteboardItem is 0 pasteboard items (docs/traps.md).
        let writer = NSPasteboardItem()
        writer.setString(witnessText, forType: .string)
        let item = NSDraggingItem(pasteboardWriter: writer)
        let mark = NSImage(size: NSSize(width: 32, height: 32))
        mark.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        mark.unlockFocus()
        item.setDraggingFrame(NSRect(x: 0, y: 0, width: 32, height: 32), contents: mark)
        report.say("item ready")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            report.say("main queue serviced during the session")
        }
        let session = beginDraggingSession(with: [item], event: event, source: self)
        report.say("begin returned sequence \(session.draggingSequenceNumber)")
    }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation { [.copy, .move] }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        // BOARD LEVEL, never NSPasteboardItem: the item path validates a type
        // string as a UTI and drops a MIME-shaped id with a console log.
        let board = session.draggingPasteboard
        board.clearContents()
        var types: [NSPasteboard.PasteboardType] = [.init(mimeID), .string]
        if filePath != nil { types.append(.fileURL) }
        board.declareTypes(types, owner: nil)
        board.setData(Data(witnessNote.utf8), forType: .init(mimeID))
        board.setString(witnessText, forType: .string)
        if let filePath {
            board.setString(URL(fileURLWithPath: filePath).absoluteString, forType: .fileURL)
        }
        report.say("session began")
    }

    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        var word = "none"
        if operation.contains(.move) {
            word = "move"
        } else if operation.contains(.copy) {
            word = "copy"
        }
        report.say("drag ended \(word)")
        onEnded?()
    }
}

// ---- the app -----------------------------------------------------------
let rect = numbers("at", 4)
let app = NSApplication.shared
app.setActivationPolicy(opts["policy"] == "regular" ? .regular : .accessory)
let window = NSWindow(
    contentRect: NSRect(
        x: rect[0], y: mainScreenHeight - rect[1] - rect[3], width: rect[2], height: rect[3]),
    styleMask: [.titled], backing: .buffered, defer: false)
window.title = "kaya drag witness"
window.level = .floating
window.isReleasedWhenClosed = false

let done = DispatchSemaphore(value: 0)
if mode == "catch" {
    let v = CatchView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
    v.onDrop = { done.signal() }
    window.contentView = v
} else {
    let v = ThrowView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
    v.filePath = opts["file"]
    v.onEnded = { done.signal() }
    window.contentView = v
}
window.orderFrontRegardless()
report.say("window \(window.frame) visible \(window.isVisible)")

// THE CONSTRUCTED-EVENT ROUTE (probe 3's `session`): beginDraggingSession
// with an NSEvent nobody delivered and no button down. Does AppKit still
// ask the source to compose its pasteboard?
if mode == "throw", opts["constructed"] != nil {
    let v = window.contentView as! ThrowView
    let writer = NSPasteboardItem()
    // AN EMPTY WRITER IS 0 PASTEBOARD ITEMS AND AppKit THROWS (measured
    // 2026-09-03): "There are 0 items on the pasteboard, but 1 drag images."
    if opts["constructed"] == "empty" {
        // the shipped shape, kept so the negative is watched
    } else {
        writer.setString("placeholder", forType: .string)
    }
    let item = NSDraggingItem(pasteboardWriter: writer)
    item.setDraggingFrame(NSRect(x: 0, y: 0, width: 10, height: 10), contents: nil)
    guard let ev = NSEvent.mouseEvent(
        with: .leftMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
        clickCount: 1, pressure: 1)
    else { die("no constructed event") }
    let session = v.beginDraggingSession(with: [item], event: ev, source: v)
    let board = session.draggingPasteboard
    report.say("constructed board \(board.name.rawValue)")
    report.say("constructed types \((board.types?.map(\.rawValue) ?? []).joined(separator: " "))")
    report.say("constructed text \(board.string(forType: .string) ?? "<nil>")")
    report.write()
    exit(0)
}

let hold = opts["hold"].flatMap { Double($0) } ?? 12
DispatchQueue.global().async {
    _ = done.wait(timeout: .now() + hold)
    usleep(400_000)
    report.write()
    DispatchQueue.main.async { app.terminate(nil) }
}

// A witness that wedges must not take the leg with it.
let watchdog = Thread {
    Thread.sleep(forTimeInterval: hold + 12)
    report.say("watchdog fired")
    report.write()
    exit(9)
}
watchdog.start()

app.run()
