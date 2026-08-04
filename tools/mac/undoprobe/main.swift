// UndoProbe (macOS) — does a kaya programmatic text write land in the
// field's native undo stack, and which NSUndoManager answers for a
// focused kaya TextField?
//
// THE QUESTIONS THAT DECIDE D7's AND D6's MAC SPELLING
// (docs/undo-plan.md §0). This file mirrors kaya's ACTUAL lowering —
// swift/KayaSwiftUI.swift:7213 KayaEntry is a SwiftUI TextField over an
// @Observable node, and the SetProp path (line 2492) writes
// `node.text = …` and nothing else. Measuring `NSTextField.stringValue`
// instead would answer a question kaya never asks.
//
//  Q1 WHICH RESPONDER, WHICH MANAGER. What class is first responder
//     when a SwiftUI TextField is focused on macOS 26, is it the
//     window's shared field editor, and which NSUndoManager does its
//     `undoManager` resolve to — the window's, or one of its own?
//  Q2 IS THE WINDOW'S HOOK ON THE PATH? Does AppKit consult
//     NSWindowDelegate.windowWillReturnUndoManager(_:) for that
//     responder — i.e. can kaya supply the manager per window (D6)?
//  Q3 DOES TYPING REGISTER? Synthetic key events through
//     NSApp.sendEvent must move the node's text (proof the real path
//     ran) and must leave canUndo true.
//  Q4 DOES A PROGRAMMATIC WRITE REGISTER? Set node.text, let SwiftUI
//     render, then ask canUndo / count the registrations.
//  Q5 WHAT DOES Cmd+Z DO AFTER A PROGRAMMATIC WRITE? The D7 hazard is
//     not only "the write is undoable" — it is a STALE typing action
//     replayed against content the app replaced.
//  Q6 DOES removeAllActions BUY D7? Clear on write, then undo: does
//     nothing revert?
//  Q7 WHICH ROUTE IS Edit>Undo? NSApp.sendAction(undo:) down the
//     responder chain vs a real NSMenu key-equivalent walk (what
//     kayaMacShortcut does) — do they reach the same manager?
//  Q8 TEXTAREA. Same questions for TextEditor (KayaTextarea).
//
// Answers land on stdout under "PROBE". Not a lane; nothing builds it
// but build.sh beside it. THROWAWAY.
import AppKit
import SwiftUI

func say(_ s: String) {
    print("PROBE \(s)")
    fflush(stdout)
}

// ---------------------------------------------------------------- model

/// kaya's KayaNode, reduced to the field this probe needs. The @Observable
/// class is the load-bearing part: the SetProp path writes THIS.
@Observable
final class ProbeNode {
    var text = ""
}

let entryNode = ProbeNode()
let areaNode = ProbeNode()

/// Every setter call the binding sees, so a "programmatic write" can be
/// told apart from an echo SwiftUI pushed back through the binding.
var entrySetterLog: [String] = []
var areaSetterLog: [String] = []

/// KayaEntry, verbatim in shape (KayaSwiftUI.swift:7213).
struct ProbeEntry: View {
    @Bindable var node: ProbeNode
    @FocusState private var focused: Bool
    var body: some View {
        TextField(
            "",
            text: Binding(
                get: { node.text },
                set: { newValue in
                    entrySetterLog.append(newValue)
                    node.text = newValue
                })
        )
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 200)
        .focused($focused)
        .onAppear { focused = true }
    }
}

/// KayaTextarea, verbatim in shape (KayaSwiftUI.swift:7254).
struct ProbeArea: View {
    @Bindable var node: ProbeNode
    var body: some View {
        TextEditor(
            text: Binding(
                get: { node.text },
                set: { newValue in
                    areaSetterLog.append(newValue)
                    node.text = newValue
                })
        )
        .frame(width: 240, height: 96)
        .border(Color.gray.opacity(0.4))
    }
}

struct ProbeRoot: View {
    var body: some View {
        VStack(spacing: 12) {
            ProbeEntry(node: entryNode)
            ProbeArea(node: areaNode)
        }
        .padding(20)
        .frame(width: 320, height: 200)
    }
}

// ------------------------------------------------------------ machinery

/// An NSUndoManager that says what was registered on it. Installed via
/// windowWillReturnUndoManager in mode=hook — Q2's instrument and Q4's.
final class LoggingUndoManager: UndoManager {
    let name: String
    var registrations: [String] = []
    init(name: String) {
        self.name = name
        super.init()
    }
    override func registerUndo(withTarget target: Any, selector: Selector, object: Any?) {
        registrations.append("selector \(selector) target \(type(of: target))")
        super.registerUndo(withTarget: target, selector: selector, object: object)
    }
    override func prepare(withInvocationTarget target: Any) -> Any {
        registrations.append("invocation target \(type(of: target))")
        return super.prepare(withInvocationTarget: target)
    }
    override func setActionName(_ actionName: String) {
        registrations.append("actionName \"\(actionName)\"")
        super.setActionName(actionName)
    }
}

final class WindowDelegate: NSObject, NSWindowDelegate {
    /// nil in mode=plain: the delegate does NOT implement the hook there,
    /// which is a different thing from implementing it and returning nil.
    var supplied: LoggingUndoManager?
    var asked = 0
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        asked += 1
        return supplied
    }
}

let hookMode = ProcessInfo.processInfo.environment["KAYA_UNDOPROBE_MODE"] == "hook"

func oid(_ o: AnyObject?) -> String {
    guard let o else { return "nil" }
    return "\(type(of: o))@\(UInt(bitPattern: ObjectIdentifier(o).hashValue) % 100000)"
}

/// Let AppKit + SwiftUI settle: SwiftUI re-renders on the next runloop
/// turn, so every measurement after a model write must pump first.
func pump(_ turns: Int = 8) {
    for _ in 0..<turns {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

/// A real key event through the real dispatch: NSApp.sendEvent walks
/// window -> first responder, which is the path a user's keystroke takes.
func typeKey(_ chars: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = [], window: NSWindow) {
    guard
        let down = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: keyCode)
    else {
        say("!! could not synthesize key \(chars)")
        return
    }
    NSApp.sendEvent(down)
    if let up = NSEvent.keyEvent(
        with: .keyUp, location: .zero, modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil,
        characters: chars, charactersIgnoringModifiers: chars,
        isARepeat: false, keyCode: keyCode)
    {
        NSApp.sendEvent(up)
    }
    pump(3)
}

let keyCodes: [Character: UInt16] = [
    "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "z": 6, "x": 7,
]

func typeText(_ s: String, window: NSWindow) {
    for ch in s {
        guard let code = keyCodes[ch] else {
            say("!! no keycode for \(ch)")
            continue
        }
        typeKey(String(ch), keyCode: code, window: window)
    }
}

/// The responder chain from the first responder up, with the manager
/// each link resolves to. NSResponder.undoManager itself walks the
/// chain, so the interesting fact is WHERE the walk stops.
func dumpResponderChain(_ window: NSWindow, _ tag: String) {
    var r: NSResponder? = window.firstResponder
    var depth = 0
    while let cur = r, depth < 10 {
        var line = "\(tag) chain[\(depth)] \(oid(cur))"
        line += " undoManager=\(oid(cur.undoManager))"
        if let tv = cur as? NSTextView {
            line += " allowsUndo=\(tv.allowsUndo)"
            line += " isFieldEditor=\(tv.isFieldEditor)"
            line += " delegate=\(oid(tv.delegate as AnyObject?))"
        }
        say(line)
        r = cur.nextResponder
        depth += 1
    }
}

/// The manager that actually serves the focused text: what the field
/// editor (or whatever is first responder) resolves to.
func focusedManager(_ window: NSWindow) -> UndoManager? {
    window.firstResponder?.undoManager
}

func fieldEditorInfo(_ window: NSWindow) -> String {
    guard let fe = window.fieldEditor(false, for: nil) else {
        return "no cached field editor"
    }
    let allows = (fe as? NSTextView).map { "\($0.allowsUndo)" } ?? "n/a"
    return "fieldEditor=\(oid(fe)) undoManager=\(oid(fe.undoManager)) allowsUndo=\(allows)"
}

// -------------------------------------------------------------- the run

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let winDelegate = WindowDelegate()
    var hookManager: LoggingUndoManager?

    func applicationDidFinishLaunching(_ note: Notification) {
        if hookMode {
            let m = LoggingUndoManager(name: "hooked")
            hookManager = m
            winDelegate.supplied = m
        }
        window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 320, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "UndoProbe"
        window.delegate = winDelegate
        window.contentView = NSHostingView(rootView: ProbeRoot())
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Q7's second route needs a real Edit>Undo item: nil-targeted,
        // exactly the shape AppKit's own template uses, so the
        // key-equivalent walk lands on the responder chain.
        let main = NSMenu()
        let editHolder = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        editHolder.submenu = edit
        main.addItem(editHolder)
        NSApp.mainMenu = main

        pump(20)
        DispatchQueue.main.async { self.run() }
    }

    /// Reset to a known floor between trials WITHOUT going through the
    /// thing under test: clear the manager and the model, re-focus.
    func reset(_ label: String) {
        entryNode.text = ""
        entrySetterLog.removeAll()
        pump(5)
        focusedManager(window)?.removeAllActions()
        window.undoManager?.removeAllActions()
        hookManager?.registrations.removeAll()
        pump(3)
        say("--- \(label) (floor: text=\"\(entryNode.text)\" canUndo=\(focusedManager(window)?.canUndo ?? false))")
    }

    func run() {
        say("mode=\(hookMode ? "hook" : "plain")")
        say("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        // ---- Q1/Q2: who is first responder, who is the manager
        say("firstResponder(before typing)=\(oid(window.firstResponder))")
        dumpResponderChain(window, "Q1")
        say("Q1 window.undoManager=\(oid(window.undoManager))")
        say("Q1 \(fieldEditorInfo(window))")
        say("Q2 windowWillReturnUndoManager asked=\(winDelegate.asked) supplied=\(oid(winDelegate.supplied))")

        // ---- Q3: does typing move the model AND register undo?
        reset("Q3 typing")
        typeText("abc", window: window)
        let mgr = focusedManager(window)
        say("Q3 after typing: node.text=\"\(entryNode.text)\" setterCalls=\(entrySetterLog.count)")
        say("Q3 firstResponder=\(oid(window.firstResponder))")
        say("Q3 manager=\(oid(mgr)) canUndo=\(mgr?.canUndo ?? false) canRedo=\(mgr?.canRedo ?? false)")
        say("Q3 window.undoManager canUndo=\(window.undoManager?.canUndo ?? false)")
        say("Q3 undoActionName=\"\(mgr?.undoActionName ?? "")\"")
        if let h = hookManager {
            say("Q3 hookManager registrations=\(h.registrations)")
        }

        // ---- Q7a: undo down the responder chain (Edit>Undo, nil target)
        let sentChain = NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        pump(5)
        say("Q7a sendAction(undo:) accepted=\(sentChain) node.text=\"\(entryNode.text)\"")

        // ---- Q7b: the real NSMenu key-equivalent walk (kayaMacShortcut)
        reset("Q7b menu Cmd+Z after typing")
        typeText("abc", window: window)
        say("Q7b typed: node.text=\"\(entryNode.text)\"")
        if let cmdZ = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: "z", charactersIgnoringModifiers: "z",
            isARepeat: false, keyCode: 6)
        {
            let handled = NSApp.mainMenu?.performKeyEquivalent(with: cmdZ) ?? false
            pump(6)
            say("Q7b performKeyEquivalent handled=\(handled) node.text=\"\(entryNode.text)\"")
        }

        // ---- Q4/Q5: the programmatic write
        reset("Q4/Q5 programmatic write")
        typeText("abc", window: window)
        let beforeCanUndo = focusedManager(window)?.canUndo ?? false
        let regsBefore = hookManager?.registrations.count ?? -1
        // THE SetProp PATH, verbatim: assign to the observable node.
        entryNode.text = "PROG"
        pump(10)
        let afterMgr = focusedManager(window)
        say("Q4 typed-then-wrote: node.text=\"\(entryNode.text)\" setterCalls=\(entrySetterLog.count)")
        say("Q4 manager=\(oid(afterMgr)) canUndo(before write)=\(beforeCanUndo) canUndo(after)=\(afterMgr?.canUndo ?? false)")
        if let h = hookManager {
            say("Q4 hook registrations delta=\(h.registrations.count - regsBefore) all=\(h.registrations)")
        }
        // The displayed string, not the model: SwiftUI may or may not
        // have pushed the write into the field editor.
        say("Q4 \(fieldEditorInfo(window))")
        if let fe = window.fieldEditor(false, for: nil) {
            say("Q4 fieldEditor.string=\"\(fe.string)\"")
        }
        // Now undo, and see what the stale stack does to the new content.
        let sent2 = NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        pump(8)
        say("Q5 after 1st undo: accepted=\(sent2) node.text=\"\(entryNode.text)\"")
        NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        pump(8)
        say("Q5 after 2nd undo: node.text=\"\(entryNode.text)\"")
        NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        pump(8)
        say("Q5 after 3rd undo: node.text=\"\(entryNode.text)\" canUndo=\(focusedManager(window)?.canUndo ?? false)")

        // ---- Q6: does removeAllActions on the resolved manager buy D7?
        reset("Q6 write + removeAllActions")
        typeText("abc", window: window)
        entryNode.text = "PROG"
        pump(10)
        // D7's candidate spelling: clear the field's manager at the write.
        focusedManager(window)?.removeAllActions()
        pump(3)
        let m6 = focusedManager(window)
        say("Q6 after clear: canUndo=\(m6?.canUndo ?? false) canRedo=\(m6?.canRedo ?? false) text=\"\(entryNode.text)\"")
        let sent3 = NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        pump(8)
        say("Q6 after undo: accepted=\(sent3) node.text=\"\(entryNode.text)\"")
        // And typing must still be undoable AFTER the clear — a clear
        // that breaks the native tier for good would fail D1.
        typeText("de", window: window)
        say("Q6 typed after clear: text=\"\(entryNode.text)\" canUndo=\(focusedManager(window)?.canUndo ?? false)")
        NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        pump(8)
        say("Q6 undo after re-typing: node.text=\"\(entryNode.text)\"")

        // ---- Q8: the textarea (TextEditor)
        say("--- Q8 textarea")
        // Focus it by clicking: TextEditor has no @FocusState here, so
        // move the responder directly the way a tab would.
        if let host = window.contentView {
            var found: NSView?
            func walk(_ v: NSView) {
                if let tv = v as? NSTextView, !tv.isFieldEditor { found = tv }
                for s in v.subviews { walk(s) }
            }
            walk(host)
            if let tv = found {
                window.makeFirstResponder(tv)
                pump(5)
            } else {
                say("Q8 !! no non-field-editor NSTextView found (TextEditor is not NSTextView here)")
            }
        }
        say("Q8 firstResponder=\(oid(window.firstResponder))")
        dumpResponderChain(window, "Q8")
        areaNode.text = ""
        pump(4)
        focusedManager(window)?.removeAllActions()
        typeText("abc", window: window)
        say("Q8 typed: areaNode.text=\"\(areaNode.text)\" canUndo=\(focusedManager(window)?.canUndo ?? false)")
        let regs8 = hookManager?.registrations.count ?? -1
        areaNode.text = "PROG"
        pump(10)
        say("Q8 after write: areaNode.text=\"\(areaNode.text)\" canUndo=\(focusedManager(window)?.canUndo ?? false)")
        if let h = hookManager {
            say("Q8 hook registrations delta=\(h.registrations.count - regs8)")
        }
        NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        pump(8)
        say("Q8 after undo: areaNode.text=\"\(areaNode.text)\"")
        focusedManager(window)?.removeAllActions()
        pump(3)
        NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        pump(8)
        say("Q8 after clear+undo: areaNode.text=\"\(areaNode.text)\" canUndo=\(focusedManager(window)?.canUndo ?? false)")

        say("done")
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
