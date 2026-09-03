// UndoProbe round 2 (macOS) — WHO answers Edit>Undo, whether a
// programmatic write registers anything, and how the entry's private
// NSCellUndoManager behaves across fields and focus
// (docs/undo-plan.md §0; the R-labels are in the print lines below).
// THREE MODES, not two: `nohook` = a delegate that does NOT implement
// windowWillReturnUndoManager (what kaya ships), `plainhook` = a stock
// UndoManager, `hook` = the logging subclass — implementing the method
// and returning nil is a DIFFERENT thing.
// THROWAWAY. Nothing builds it but build.sh beside it.
import AppKit
import SwiftUI

func say(_ s: String) {
    print("PROBE \(s)")
    fflush(stdout)
}

@Observable
final class ProbeNode {
    var text = ""
}

let entryA = ProbeNode()
let entryB = ProbeNode()
let areaNode = ProbeNode()

struct ProbeEntry: View {
    @Bindable var node: ProbeNode
    let autofocus: Bool
    @FocusState private var focused: Bool
    var body: some View {
        TextField("", text: Binding(get: { node.text }, set: { node.text = $0 }))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 200)
            .focused($focused)
            .onAppear { focused = autofocus }
    }
}

struct ProbeArea: View {
    @Bindable var node: ProbeNode
    var body: some View {
        TextEditor(text: Binding(get: { node.text }, set: { node.text = $0 }))
            .frame(width: 240, height: 70)
            .border(Color.gray.opacity(0.4))
    }
}

struct ProbeRoot: View {
    var body: some View {
        VStack(spacing: 10) {
            ProbeEntry(node: entryA, autofocus: true)
            ProbeEntry(node: entryB, autofocus: false)
            ProbeArea(node: areaNode)
        }
        .padding(16)
        .frame(width: 320, height: 220)
    }
}

// ------------------------------------------------------------ machinery

final class LoggingUndoManager: UndoManager {
    var registrations: [String] = []
    override func registerUndo(withTarget target: Any, selector: Selector, object: Any?) {
        registrations.append("sel \(selector)")
        super.registerUndo(withTarget: target, selector: selector, object: object)
    }
    override func prepare(withInvocationTarget target: Any) -> Any {
        registrations.append("invocation \(type(of: target))")
        return super.prepare(withInvocationTarget: target)
    }
    override func setActionName(_ actionName: String) {
        registrations.append("name \"\(actionName)\"")
        super.setActionName(actionName)
    }
}

/// The registration instrument that works on managers we do not own:
/// NSUndoManager opens a group on every registration made outside one,
/// and the notification carries the manager. Observed with object: nil,
/// so NSCellUndoManager (which no subclass can reach) is covered too.
/// The block-based registerUndo cannot be overridden at all (it lives
/// in an extension), which is why this is a notification and not a
/// subclass.
final class GroupWatch {
    var opens: [String] = []
    init() {
        NotificationCenter.default.addObserver(
            forName: .NSUndoManagerDidOpenUndoGroup, object: nil, queue: nil
        ) { note in
            let m = note.object as AnyObject?
            self.opens.append(oid(m))
        }
    }
    func drain() -> [String] {
        let out = opens
        opens.removeAll()
        return out
    }
}
let groupWatch = GroupWatch()

/// The mode with NO hook at all — a class that does not declare the
/// method, which is what kaya ships today. Implementing it and
/// returning nil is a DIFFERENT thing and round 1 conflated them.
final class BareDelegate: NSObject, NSWindowDelegate {}

final class HookDelegate: NSObject, NSWindowDelegate {
    let supplied: UndoManager
    var asked = 0
    init(_ m: UndoManager) {
        supplied = m
        super.init()
    }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        asked += 1
        return supplied
    }
}

let mode = ProcessInfo.processInfo.environment["KAYA_UNDOPROBE_MODE"] ?? "nohook"

func oid(_ o: AnyObject?) -> String {
    guard let o else { return "nil" }
    return "\(type(of: o))@\(UInt(bitPattern: ObjectIdentifier(o).hashValue) % 100000)"
}

func pump(_ turns: Int = 8) {
    for _ in 0..<turns {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

let keyCodes: [Character: UInt16] = ["a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "z": 6]

func typeText(_ s: String, window: NSWindow) {
    for ch in s {
        guard let code = keyCodes[ch] else { continue }
        for kind in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(
                with: kind, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: String(ch), charactersIgnoringModifiers: String(ch),
                isARepeat: false, keyCode: code)
            {
                NSApp.sendEvent(e)
            }
        }
        pump(3)
    }
}

/// Every NSTextField/NSTextView in the hierarchy, in order — R5 needs to
/// tell entry A's editor from entry B's.
func textControls(_ root: NSView) -> [NSView] {
    var out: [NSView] = []
    func walk(_ v: NSView) {
        if v is NSTextField || (v is NSTextView && !(v as! NSTextView).isFieldEditor) {
            out.append(v)
        }
        for s in v.subviews { walk(s) }
    }
    walk(root)
    return out
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var bare = BareDelegate()
    var hook: HookDelegate?
    var logger: LoggingUndoManager?

    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 320, height: 220),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "UndoProbe2"
        switch mode {
        case "hook":
            let m = LoggingUndoManager()
            logger = m
            hook = HookDelegate(m)
            window.delegate = hook
        case "plainhook":
            hook = HookDelegate(UndoManager())
            window.delegate = hook
        default:
            window.delegate = bare
        }
        window.contentView = NSHostingView(rootView: ProbeRoot())
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let main = NSMenu()
        let holder = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        holder.submenu = edit
        main.addItem(holder)
        NSApp.mainMenu = main

        pump(20)
        DispatchQueue.main.async { self.run() }
    }

    func mgr() -> UndoManager? { window.firstResponder?.undoManager }

    /// R1: who takes `undo:`, and does each candidate even respond to it?
    func routeReport(_ tag: String) {
        let sel = Selector(("undo:"))
        let target = NSApp.target(forAction: sel, to: nil, from: nil) as AnyObject?
        say("\(tag) R1 NSApp.target(undo:)=\(oid(target))")
        if let fr = window.firstResponder {
            let supp = fr.supplementalTarget(forAction: sel, sender: nil) as AnyObject?
            say("\(tag) R1 firstResponder=\(oid(fr)) supplementalTarget=\(oid(supp))")
        }
        say("\(tag) R1 focusedManager=\(oid(mgr())) responds(undo:)=\((mgr() as AnyObject?)?.responds(to: sel) ?? false)")
        say("\(tag) R1 window.undoManager=\(oid(window.undoManager))")
    }

    func run() {
        say("mode=\(mode)")
        pump(6)
        routeReport("T0")

        // ---- R3: a programmatic write on an EMPTY stack
        say("--- R3 write-only on an empty stack")
        entryA.text = ""
        pump(5)
        mgr()?.removeAllActions()
        window.undoManager?.removeAllActions()
        pump(3)
        say("R3 floor: text=\"\(entryA.text)\" canUndo=\(mgr()?.canUndo ?? false)")
        entryA.text = "PROG"
        pump(10)
        say("R3 after write: text=\"\(entryA.text)\" canUndo=\(mgr()?.canUndo ?? false) canRedo=\(mgr()?.canRedo ?? false)")
        say("R3 groups opened during write=\(groupWatch.drain())")
        say("R3 window.undoManager canUndo=\(window.undoManager?.canUndo ?? false)")
        if let l = logger { say("R3 hook registrations=\(l.registrations)") }
        mgr()?.undo()
        pump(8)
        say("R3 after direct undo(): text=\"\(entryA.text)\"")

        // ---- R4: the stack, not the route — entry
        say("--- R4 entry: type, write, direct undo()")
        entryA.text = ""
        pump(5)
        mgr()?.removeAllActions()
        pump(3)
        _ = groupWatch.drain()
        typeText("abc", window: window)
        say("R4 groups opened during typing=\(groupWatch.drain())")
        say("R4 typed: text=\"\(entryA.text)\" canUndo=\(mgr()?.canUndo ?? false) name=\"\(mgr()?.undoActionName ?? "")\"")
        entryA.text = "PROG"
        pump(10)
        say("R4 after write: text=\"\(entryA.text)\" canUndo=\(mgr()?.canUndo ?? false) name=\"\(mgr()?.undoActionName ?? "")\"")
        say("R4 groups opened during write=\(groupWatch.drain())")
        if let l = logger { say("R4 hook registrations=\(l.registrations)") }
        mgr()?.undo()
        pump(8)
        say("R4 after direct undo(): text=\"\(entryA.text)\" canUndo=\(mgr()?.canUndo ?? false) canRedo=\(mgr()?.canRedo ?? false)")
        mgr()?.undo()
        pump(8)
        say("R4 after 2nd direct undo(): text=\"\(entryA.text)\"")

        // ---- R4b: the same, with the D7 clear at the write
        say("--- R4b entry: type, write+clear, direct undo()")
        entryA.text = ""
        pump(5)
        mgr()?.removeAllActions()
        typeText("abc", window: window)
        entryA.text = "PROG"
        pump(10)
        mgr()?.removeAllActions()
        pump(3)
        say("R4b after write+clear: text=\"\(entryA.text)\" canUndo=\(mgr()?.canUndo ?? false) canRedo=\(mgr()?.canRedo ?? false)")
        mgr()?.undo()
        pump(8)
        say("R4b after direct undo(): text=\"\(entryA.text)\"")
        routeReport("R4b")
        // And the routed chord, for the modes where the route survives.
        typeText("de", window: window)
        say("R4b typed after clear: text=\"\(entryA.text)\" canUndo=\(mgr()?.canUndo ?? false)")
        let accepted = NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        pump(8)
        say("R4b routed undo accepted=\(accepted) text=\"\(entryA.text)\"")

        // ---- R5: is the private manager per FIELD?
        say("--- R5 two entries")
        let controls = textControls(window.contentView!)
        say("R5 controls=\(controls.map { oid($0) })")
        let managerA = oid(mgr())
        // Focus entry B by making its field editor first responder.
        if controls.count >= 2, let fieldB = controls[1] as? NSTextField {
            window.makeFirstResponder(fieldB)
            pump(6)
        }
        say("R5 after focusing B: firstResponder=\(oid(window.firstResponder)) manager=\(oid(mgr()))")
        say("R5 managerA=\(managerA) managerB=\(oid(mgr())) same=\(managerA == oid(mgr()))")
        entryB.text = ""
        pump(4)
        mgr()?.removeAllActions()
        typeText("de", window: window)
        say("R5 typed in B: B=\"\(entryB.text)\" A=\"\(entryA.text)\" canUndo=\(mgr()?.canUndo ?? false)")

        // ---- R7: does A's history survive the round trip?
        if let fieldA = controls.first as? NSTextField {
            window.makeFirstResponder(fieldA)
            pump(6)
        }
        say("R7 back on A: firstResponder=\(oid(window.firstResponder)) manager=\(oid(mgr())) canUndo=\(mgr()?.canUndo ?? false) name=\"\(mgr()?.undoActionName ?? "")\"")
        mgr()?.undo()
        pump(8)
        say("R7 undo on A after round trip: A=\"\(entryA.text)\" B=\"\(entryB.text)\"")

        // ---- R6: a write while UNFOCUSED
        say("--- R6 unfocused write")
        // Park focus on B, write to A, then focus A.
        if controls.count >= 2, let fieldB = controls[1] as? NSTextField {
            window.makeFirstResponder(fieldB)
            pump(6)
        }
        entryA.text = "SET-WHILE-BLUR"
        pump(10)
        if let fieldA = controls.first as? NSTextField {
            window.makeFirstResponder(fieldA)
            pump(8)
        }
        say("R6 focused A after blurred write: text=\"\(entryA.text)\" manager=\(oid(mgr())) canUndo=\(mgr()?.canUndo ?? false) name=\"\(mgr()?.undoActionName ?? "")\"")
        mgr()?.undo()
        pump(8)
        say("R6 after direct undo(): A=\"\(entryA.text)\"")

        // ---- R4c: the textarea, stack vs route
        say("--- R4c textarea")
        if let tv = controls.compactMap({ $0 as? NSTextView }).first {
            window.makeFirstResponder(tv)
            pump(6)
        }
        routeReport("R4c")
        areaNode.text = ""
        pump(5)
        mgr()?.removeAllActions()
        pump(3)
        // Does a write on an empty stack register here?
        areaNode.text = "PROG"
        pump(10)
        say("R4c write-only: text=\"\(areaNode.text)\" canUndo=\(mgr()?.canUndo ?? false) groups=\(groupWatch.drain())")
        if let l = logger { say("R4c hook registrations=\(l.registrations)") }
        areaNode.text = ""
        pump(5)
        mgr()?.removeAllActions()
        typeText("abc", window: window)
        say("R4c typed: text=\"\(areaNode.text)\" canUndo=\(mgr()?.canUndo ?? false) name=\"\(mgr()?.undoActionName ?? "")\"")
        if let l = logger { say("R4c hook registrations after typing=\(l.registrations)") }
        areaNode.text = "PROG"
        pump(10)
        say("R4c after write: text=\"\(areaNode.text)\" canUndo=\(mgr()?.canUndo ?? false) groups=\(groupWatch.drain())")
        mgr()?.undo()
        pump(8)
        say("R4c after direct undo(): text=\"\(areaNode.text)\"")
        // The clear
        areaNode.text = ""
        pump(5)
        mgr()?.removeAllActions()
        typeText("abc", window: window)
        areaNode.text = "PROG"
        pump(10)
        mgr()?.removeAllActions()
        pump(3)
        say("R4c write+clear: text=\"\(areaNode.text)\" canUndo=\(mgr()?.canUndo ?? false)")
        mgr()?.undo()
        pump(8)
        say("R4c after clear+undo(): text=\"\(areaNode.text)\"")
        // THE COLLISION D6 HAS TO KNOW ABOUT: on a textarea the manager
        // IS the window's, so clearing it would also clear anything the
        // app registered there.
        say("R4c manager===window.undoManager: \(mgr() === window.undoManager)")

        say("done")
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
