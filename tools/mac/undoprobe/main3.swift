// UndoProbe round 3 (macOS) — the decisive run, with the artifact that
// spoiled rounds 1 and 2 removed.
//
// THE ARTIFACT: rounds 1-2 ran three modes back to back from one
// script, so every difference between them tracked LAUNCH ORDER rather
// than the hook mode — only the first launch became the active app, and
// `NSApp.target(forAction: undo:)` came back nil in the others. This one
// WAITS for the window to become key and says so, and reads at THREE
// layers (the kaya model, the NSTextField's stringValue, the field
// editor's string), because "the undo did not happen" and "the undo
// happened and never reached the model" are different findings.
//
// One mode per process. Run it three times; see build3.sh.
//
// THROWAWAY. Nothing builds it but build3.sh beside it.
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

final class GroupWatch {
    var opens: [String] = []
    init() {
        NotificationCenter.default.addObserver(
            forName: .NSUndoManagerDidOpenUndoGroup, object: nil, queue: nil
        ) { note in self.opens.append(oid(note.object as AnyObject?)) }
    }
    func drain() -> [String] {
        let out = opens
        opens.removeAll()
        return out
    }
}

func oid(_ o: AnyObject?) -> String {
    guard let o else { return "nil" }
    return "\(type(of: o))@\(UInt(bitPattern: ObjectIdentifier(o).hashValue) % 100000)"
}

let groupWatch = GroupWatch()

/// No hook at all: what kaya ships today.
final class BareDelegate: NSObject, NSWindowDelegate {}

/// D6's candidate plumbing: the window hands out a manager kaya owns.
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

func textControls(_ root: NSView) -> [NSView] {
    var out: [NSView] = []
    func walk(_ v: NSView) {
        if v is NSTextField { out.append(v) }
        if let tv = v as? NSTextView, !tv.isFieldEditor { out.append(tv) }
        for s in v.subviews { walk(s) }
    }
    walk(root)
    return out
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var bare = BareDelegate()
    var hook: HookDelegate?
    var controls: [NSView] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 240, y: 240, width: 320, height: 220),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "UndoProbe3"
        if mode == "hook" {
            hook = HookDelegate(UndoManager())
            window.delegate = hook
        } else {
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

        DispatchQueue.main.async { self.run() }
    }

    func mgr() -> UndoManager? { window.firstResponder?.undoManager }

    /// The three layers. A native undo that moves the AppKit text but
    /// not the model is a DIFFERENT defect from one that does nothing.
    func layers(_ tag: String, control: NSView?) {
        var appkit = "n/a"
        if let f = control as? NSTextField { appkit = "\"\(f.stringValue)\"" }
        if let tv = control as? NSTextView { appkit = "\"\(tv.string)\"" }
        var fe = "none"
        if let editor = window.fieldEditor(false, for: control) {
            fe = "\"\(editor.string)\""
        }
        say(
            "\(tag) model=\"\(entryA.text)\"/\"\(entryB.text)\"/\"\(areaNode.text)\" appkit=\(appkit) fieldEditor=\(fe)"
        )
    }

    func state(_ tag: String) {
        let m = mgr()
        say(
            "\(tag) mgr=\(oid(m)) canUndo=\(m?.canUndo ?? false) canRedo=\(m?.canRedo ?? false) name=\"\(m?.undoActionName ?? "")\""
        )
    }

    /// The routed undo (a nil-targeted Edit>Undo) AND the direct one, so
    /// a hijacked route cannot masquerade as an empty stack.
    func routedUndo(_ tag: String) -> Bool {
        let sel = Selector(("undo:"))
        let target = NSApp.target(forAction: sel, to: nil, from: nil) as AnyObject?
        let accepted = NSApp.sendAction(sel, to: nil, from: nil)
        pump(8)
        say("\(tag) routed undo: target=\(oid(target)) accepted=\(accepted)")
        return accepted
    }

    func focus(_ v: NSView?) {
        guard let v else { return }
        window.makeFirstResponder(v)
        pump(8)
    }

    /// G/H's flag: did the WINDOW manager's action run?
    var appAction = "unfired"

    /// D6 says enablement is computed live at activation. On mac the
    /// nil-targeted item is validated by AppKit itself — measure it
    /// rather than assume, by asking the menu to update.
    private func undoItem() -> NSMenuItem? {
        NSApp.mainMenu?.items.first?.submenu?.items.first
    }
    func undoItemEnabled() -> Bool {
        NSApp.mainMenu?.items.first?.submenu?.update()
        return undoItem()?.isEnabled ?? false
    }
    func undoItemTitle() -> String { undoItem()?.title ?? "" }

    func run() {
        say("mode=\(mode)")
        // THE WAIT THAT ROUNDS 1-2 LACKED.
        var waited = 0
        while !window.isKeyWindow && waited < 100 {
            pump(2)
            waited += 1
        }
        say(
            "activation: NSApp.isActive=\(NSApp.isActive) isKeyWindow=\(window.isKeyWindow) keyWindow=\(oid(NSApp.keyWindow)) waitedTurns=\(waited)"
        )
        pump(10)
        controls = textControls(window.contentView!)
        say("controls=\(controls.map { oid($0) })")
        let fieldA = controls.first
        let fieldB = controls.count > 1 ? controls[1] : nil
        let area = controls.compactMap { $0 as? NSTextView }.first

        focus(fieldA)
        say("firstResponder=\(oid(window.firstResponder))")
        say(
            "route: NSApp.target(undo:)=\(oid(NSApp.target(forAction: Selector(("undo:")), to: nil, from: nil) as AnyObject?))"
        )
        say("window.undoManager=\(oid(window.undoManager)) hookAsked=\(hook?.asked ?? -1)")

        // ===== A: entry, programmatic write on an EMPTY stack
        say("--- A entry: write on an empty stack")
        entryA.text = ""
        pump(6)
        mgr()?.removeAllActions()
        pump(3)
        _ = groupWatch.drain()
        state("A floor")
        entryA.text = "PROG"
        pump(12)
        state("A after write")
        say("A groups=\(groupWatch.drain())")
        layers("A after write", control: fieldA)
        _ = routedUndo("A")
        layers("A after routed undo", control: fieldA)
        state("A after routed undo")

        // ===== B: entry, type then write then undo  (THE D7 CASE)
        say("--- B entry: type, write, undo")
        entryA.text = ""
        pump(6)
        mgr()?.removeAllActions()
        pump(3)
        _ = groupWatch.drain()
        typeText("abc", window: window)
        state("B after typing")
        layers("B after typing", control: fieldA)
        say("B groups(typing)=\(groupWatch.drain())")
        entryA.text = "PROG"
        pump(12)
        state("B after write")
        layers("B after write", control: fieldA)
        say("B groups(write)=\(groupWatch.drain())")
        _ = routedUndo("B")
        layers("B after 1st undo", control: fieldA)
        state("B after 1st undo")
        _ = routedUndo("B2")
        layers("B after 2nd undo", control: fieldA)

        // ===== C: entry, type, write + removeAllActions, undo  (D7 FIX)
        say("--- C entry: type, write+clear, undo")
        entryA.text = ""
        pump(6)
        mgr()?.removeAllActions()
        pump(3)
        typeText("abc", window: window)
        entryA.text = "PROG"
        pump(12)
        mgr()?.removeAllActions()
        pump(4)
        state("C after write+clear")
        layers("C after write+clear", control: fieldA)
        _ = routedUndo("C")
        layers("C after undo", control: fieldA)
        typeText("de", window: window)
        state("C after re-typing")
        layers("C after re-typing", control: fieldA)
        _ = routedUndo("C2")
        layers("C after undo of re-typing", control: fieldA)

        // ===== D: the textarea, same three cases
        say("--- D textarea")
        focus(area)
        say("D firstResponder=\(oid(window.firstResponder))")
        state("D floor0")
        say("D mgr===window.undoManager: \(mgr() === window.undoManager)")
        areaNode.text = ""
        pump(6)
        mgr()?.removeAllActions()
        pump(3)
        _ = groupWatch.drain()
        areaNode.text = "PROG"
        pump(12)
        state("D after write-only")
        say("D groups(write-only)=\(groupWatch.drain())")
        layers("D after write-only", control: area)

        areaNode.text = ""
        pump(6)
        mgr()?.removeAllActions()
        pump(3)
        typeText("abc", window: window)
        state("D after typing")
        layers("D after typing", control: area)
        areaNode.text = "PROG"
        pump(12)
        state("D after write")
        layers("D after write", control: area)
        _ = routedUndo("D")
        layers("D after undo", control: area)

        areaNode.text = ""
        pump(6)
        mgr()?.removeAllActions()
        typeText("abc", window: window)
        areaNode.text = "PROG"
        pump(12)
        mgr()?.removeAllActions()
        pump(4)
        state("D after write+clear")
        _ = routedUndo("Dc")
        layers("D after clear+undo", control: area)
        typeText("de", window: window)
        state("D after re-typing")
        _ = routedUndo("Dc2")
        layers("D after undo of re-typing", control: area)

        // ===== E: per-field managers and the focus round trip
        say("--- E per-field managers")
        focus(fieldA)
        let mA1 = oid(mgr())
        entryA.text = ""
        pump(6)
        mgr()?.removeAllActions()
        typeText("abc", window: window)
        state("E A typed")
        focus(fieldB)
        let mB = oid(mgr())
        say("E managerA=\(mA1) managerB=\(mB) same=\(mA1 == mB)")
        entryB.text = ""
        pump(6)
        mgr()?.removeAllActions()
        typeText("de", window: window)
        state("E B typed")
        layers("E B typed", control: fieldB)
        focus(fieldA)
        let mA2 = oid(mgr())
        say("E back on A: manager=\(mA2) sameAsBefore=\(mA1 == mA2)")
        state("E back on A")
        _ = routedUndo("E")
        layers("E after undo on refocused A", control: fieldA)

        // ===== F: a write while the field is NOT focused
        say("--- F unfocused write")
        focus(fieldB)
        entryA.text = "BLURWRITE"
        pump(12)
        focus(fieldA)
        state("F focused A after blurred write")
        layers("F focused A after blurred write", control: fieldA)
        _ = routedUndo("F")
        layers("F after undo", control: fieldA)

        // ===== G/H: DOES Edit>Undo FALL THROUGH? D6's whole routing
        // question. Put an action in the WINDOW's manager, then route
        // undo with the focused entry's own manager (a) empty and
        // (b) holding typing. If AppKit already does focused-text-first
        // with fall-through, D6's mac arm is free.
        say("--- G/H fall-through")
        focus(fieldA)
        entryA.text = ""
        // CLEAR AFTER THE RENDER, NOT AFTER THE MODEL WRITE. SwiftUI
        // pushes the new value into the AppKit control on a later
        // runloop turn, and THAT push is what registers — a clear timed
        // to the model write is undone by the render that follows it.
        // The loop makes the precondition provable instead of hoped for.
        var tries = 0
        while tries < 10 {
            pump(8)
            mgr()?.removeAllActions()
            pump(4)
            if !(mgr()?.canUndo ?? false) { break }
            tries += 1
        }
        say("G floor tries=\(tries) canUndo=\(mgr()?.canUndo ?? false)")
        appAction = "unfired"
        window.undoManager?.removeAllActions()
        window.undoManager?.registerUndo(withTarget: self) { me in
            me.appAction = "FIRED"
        }
        window.undoManager?.setActionName("App Step")
        pump(4)
        say(
            "G armed: window.undoManager=\(oid(window.undoManager)) canUndo=\(window.undoManager?.canUndo ?? false) name=\"\(window.undoManager?.undoActionName ?? "")\""
        )
        state("G focused-entry manager (empty)")
        say("G menu Undo enabled=\(undoItemEnabled()) title=\"\(undoItemTitle())\"")
        _ = routedUndo("G")
        say("G appAction=\(appAction) entryA=\"\(entryA.text)\"")

        // H: now the entry HAS typing, and the window manager is armed.
        appAction = "unfired"
        window.undoManager?.removeAllActions()
        window.undoManager?.registerUndo(withTarget: self) { me in
            me.appAction = "FIRED"
        }
        window.undoManager?.setActionName("App Step")
        entryA.text = ""
        pump(6)
        mgr()?.removeAllActions()
        typeText("abc", window: window)
        state("H focused-entry manager (typing)")
        say("H menu Undo enabled=\(undoItemEnabled()) title=\"\(undoItemTitle())\"")
        _ = routedUndo("H")
        say("H appAction=\(appAction) entryA=\"\(entryA.text)\"")
        say("H after 1st undo: menu title=\"\(undoItemTitle())\" enabled=\(undoItemEnabled())")
        _ = routedUndo("H2")
        say("H2 appAction=\(appAction) entryA=\"\(entryA.text)\"")

        // I: the same two states with the TEXTAREA focused — its manager
        // IS the window's, so "fall-through" cannot even be asked there.
        say("--- I textarea shares the window manager")
        focus(area)
        appAction = "unfired"
        window.undoManager?.removeAllActions()
        window.undoManager?.registerUndo(withTarget: self) { me in
            me.appAction = "FIRED"
        }
        areaNode.text = ""
        pump(6)
        typeText("abc", window: window)
        state("I textarea after typing on an armed window manager")
        _ = routedUndo("I")
        say("I appAction=\(appAction) areaNode=\"\(areaNode.text)\"")
        appAction = "unfired"
        _ = routedUndo("I2")
        say("I2 appAction=\(appAction) areaNode=\"\(areaNode.text)\"")

        // ===== J: kaya's OWN dispatch helper. kayaPerformClipboardRole
        // reaches the responder through kayaSendToFocusedResponder,
        // which tries `firstResponder.tryToPerform` FIRST and only then
        // NSApp.sendAction (KayaSwiftUI.swift:5866). If undo: is added
        // as a role it will travel that path, so measure that path.
        say("--- J kaya's dispatch helper shape")
        focus(fieldA)
        entryA.text = ""
        var jTries = 0
        while jTries < 10 {
            pump(8)
            mgr()?.removeAllActions()
            pump(4)
            if !(mgr()?.canUndo ?? false) { break }
            jTries += 1
        }
        appAction = "unfired"
        window.undoManager?.removeAllActions()
        window.undoManager?.registerUndo(withTarget: self) { me in me.appAction = "FIRED" }
        typeText("abc", window: window)
        state("J after typing")
        let jTry = window.firstResponder?.tryToPerform(Selector(("undo:")), with: nil) ?? false
        pump(8)
        say("J tryToPerform(undo:) from firstResponder=\(jTry) entryA=\"\(entryA.text)\" appAction=\(appAction)")
        let jTry2 = window.firstResponder?.tryToPerform(Selector(("undo:")), with: nil) ?? false
        pump(8)
        say("J 2nd tryToPerform=\(jTry2) entryA=\"\(entryA.text)\" appAction=\(appAction)")

        say("done")
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
