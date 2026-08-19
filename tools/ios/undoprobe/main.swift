// UndoProbe (iOS simulator) — does a kaya programmatic text write land
// in the field's native undo stack, which UndoManager serves a focused
// kaya TextField/TextEditor, and does shake-to-undo present the system
// UI (P3-ios and P6, docs/undo-plan.md §0).
//
// The SIMULATOR is the right host: these are UIKit questions, not
// sandbox ones, and the simulator runs the same UIKit (the rule
// tools/ios/clipprobe/build.sh's header states).
//
// The app is shaped like kaya's: a SwiftUI `App` with a
// `@UIApplicationDelegateAdaptor` whose delegate SUBCLASSES UIResponder
// (swift/KayaSwiftUIEntry.swift), and the two text views are KayaEntry
// and KayaTextarea copied in shape — TextField/TextEditor over an
// `@Observable` node, uncontrolled toward the app.
//
// The cells and their answers are docs/undo-plan.md §0; the I- and
// P-labels below mark which reading is which.
//
// Answers land on stdout under "PROBE". THROWAWAY; nothing builds it
// but build.sh beside it.
import SwiftUI
import UIKit

func say(_ s: String) {
    print("PROBE \(s)")
    fflush(stdout)
}

func oid(_ o: AnyObject?) -> String {
    guard let o else { return "nil" }
    return "\(type(of: o))@\(UInt(bitPattern: ObjectIdentifier(o).hashValue) % 100000)"
}

@Observable
final class ProbeNode {
    var text = ""
}

let entryA = ProbeNode()
let entryB = ProbeNode()
let areaNode = ProbeNode()

enum Focused: Hashable { case a, b, area }

/// KayaEntry's shape (swift/KayaSwiftUI.swift:7213).
struct ProbeEntry: View {
    @Bindable var node: ProbeNode
    let tag: Focused
    var focus: FocusState<Focused?>.Binding
    var body: some View {
        TextField("", text: Binding(get: { node.text }, set: { node.text = $0 }))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 200)
            .focused(focus, equals: tag)
    }
}

/// KayaTextarea's shape (swift/KayaSwiftUI.swift:7254).
struct ProbeArea: View {
    @Bindable var node: ProbeNode
    var focus: FocusState<Focused?>.Binding
    var body: some View {
        TextEditor(text: Binding(get: { node.text }, set: { node.text = $0 }))
            .frame(width: 240, height: 90)
            .border(Color.gray.opacity(0.4))
            .focused(focus, equals: .area)
    }
}

struct ProbeRoot: View {
    @FocusState private var focus: Focused?
    var body: some View {
        VStack(spacing: 14) {
            ProbeEntry(node: entryA, tag: .a, focus: $focus)
            ProbeEntry(node: entryB, tag: .b, focus: $focus)
            ProbeArea(node: areaNode, focus: $focus)
        }
        .padding(24)
        .onAppear {
            focus = .a
            Runner.shared.setFocus = { where_ in focus = where_ }
            Task { await Runner.shared.run() }
        }
    }
}

/// The group instrument: NSUndoManager opens a group on any registration
/// made outside one, and the notification names the manager — so a
/// manager kaya does not own is still observable.
final class GroupWatch {
    static let shared = GroupWatch()
    var opens: [String] = []
    private init() {
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

@MainActor
func keyWindow() -> UIWindow? {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first { $0.isKeyWindow }
}

/// No public API names the first responder, so walk for it — the same
/// thing KayaSwiftUI's own comment says about iOS dispatch.
@MainActor
func firstResponder() -> UIResponder? {
    func walk(_ v: UIView) -> UIResponder? {
        if v.isFirstResponder { return v }
        for s in v.subviews { if let r = walk(s) { return r } }
        return nil
    }
    guard let w = keyWindow() else { return nil }
    return walk(w)
}

@MainActor
func textInputs() -> [UIView] {
    var out: [UIView] = []
    func walk(_ v: UIView) {
        if v is UITextField || v is UITextView { out.append(v) }
        for s in v.subviews { walk(s) }
    }
    if let w = keyWindow() { walk(w) }
    return out
}

@MainActor
final class Runner {
    static let shared = Runner()
    var setFocus: ((Focused?) -> Void)?

    func settle(_ ms: UInt64 = 220) async {
        try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    func mgr() -> UndoManager? { firstResponder()?.undoManager }

    func state(_ tag: String) {
        let m = mgr()
        say(
            "\(tag) fr=\(oid(firstResponder())) mgr=\(oid(m)) canUndo=\(m?.canUndo ?? false) canRedo=\(m?.canRedo ?? false) name=\"\(m?.undoActionName ?? "")\""
        )
    }

    func layers(_ tag: String, _ v: UIView?) {
        var native = "n/a"
        if let f = v as? UITextField { native = "\"\(f.text ?? "")\"" }
        if let t = v as? UITextView { native = "\"\(t.text ?? "")\"" }
        say("\(tag) model=\"\(entryA.text)\"/\"\(entryB.text)\"/\"\(areaNode.text)\" native=\(native)")
    }

    /// The keyboard's own entry point. Not a synthetic touch — iOS has
    /// no in-process way to press a key — but `insertText` IS what
    /// UIKit's keyboard calls on the UIKeyInput responder, and the
    /// model text moving proves the binding path ran.
    func type(_ s: String) async {
        guard let ki = firstResponder() as? UIKeyInput else {
            say("!! first responder is not UIKeyInput: \(oid(firstResponder()))")
            return
        }
        for ch in s {
            ki.insertText(String(ch))
            await settle(90)
        }
    }

    func chain(_ tag: String) {
        var r = firstResponder()
        var depth = 0
        while let cur = r, depth < 8 {
            var line = "\(tag) chain[\(depth)] \(oid(cur)) undoManager=\(oid(cur.undoManager))"
            if let tv = cur as? UITextView { line += " allowsEditingTextAttributes=\(tv.allowsEditingTextAttributes)" }
            say(line)
            r = cur.next
            depth += 1
        }
    }

    func focus(_ where_: Focused?) async {
        setFocus?(where_)
        await settle(400)
    }

    /// Clear the resolved manager and PROVE the floor — a clear timed to
    /// a model write is undone by the render that follows it (the mac
    /// probe hit exactly that).
    func clearFloor(_ tag: String) async {
        var tries = 0
        while tries < 8 {
            await settle(150)
            mgr()?.removeAllActions()
            await settle(150)
            if !(mgr()?.canUndo ?? false) { break }
            tries += 1
        }
        say("\(tag) floor tries=\(tries) canUndo=\(mgr()?.canUndo ?? false)")
    }

    func run() async {
        await settle(900)
        say("iOS \(UIDevice.current.systemVersion) device=\(UIDevice.current.model)")
        say(
            "P6 applicationSupportsShakeToEdit(default)=\(UIApplication.shared.applicationSupportsShakeToEdit)"
        )
        say("delegate=\(oid(UIApplication.shared.delegate as AnyObject?))")
        say("UIApplication.undoManager=\(oid(UIApplication.shared.undoManager))")

        await focus(.a)
        state("I1")
        chain("I1")
        let inputs = textInputs()
        say("I1 inputs=\(inputs.map { oid($0) })")
        let fieldA = inputs.first { $0 is UITextField }
        let fieldB = inputs.filter { $0 is UITextField }.dropFirst().first
        let area = inputs.first { $0 is UITextView }
        say("I1 fieldA=\(oid(fieldA)) fieldB=\(oid(fieldB)) area=\(oid(area))")
        if let f = fieldA { say("I1 fieldA.undoManager=\(oid(f.undoManager))") }
        if let f = fieldB { say("I1 fieldB.undoManager=\(oid(f.undoManager))") }
        if let a = area { say("I1 area.undoManager=\(oid(a.undoManager))") }
        say("I1 window.undoManager=\(oid(keyWindow()?.undoManager))")

        // ===== A: entry, programmatic write on an empty stack
        say("--- A entry: write on an empty stack")
        entryA.text = ""
        await clearFloor("A")
        _ = GroupWatch.shared.drain()
        entryA.text = "PROG"
        await settle(400)
        state("A after write")
        say("A groups=\(GroupWatch.shared.drain())")
        layers("A after write", fieldA)
        mgr()?.undo()
        await settle(400)
        layers("A after undo", fieldA)
        state("A after undo")

        // ===== B: entry, type then write then undo  (THE D7 CASE)
        say("--- B entry: type, write, undo")
        entryA.text = ""
        await clearFloor("B")
        _ = GroupWatch.shared.drain()
        await type("abc")
        state("B after typing")
        layers("B after typing", fieldA)
        say("B groups(typing)=\(GroupWatch.shared.drain())")
        entryA.text = "PROG"
        await settle(400)
        state("B after write")
        layers("B after write", fieldA)
        say("B groups(write)=\(GroupWatch.shared.drain())")
        mgr()?.undo()
        await settle(400)
        layers("B after 1st undo", fieldA)
        state("B after 1st undo")
        mgr()?.undo()
        await settle(400)
        layers("B after 2nd undo", fieldA)

        // ===== C: entry, type, write+clear, undo  (D7's candidate fix)
        say("--- C entry: type, write+clear, undo")
        entryA.text = ""
        await clearFloor("C")
        await type("abc")
        entryA.text = "PROG"
        await settle(400)
        mgr()?.removeAllActions()
        await settle(250)
        state("C after write+clear")
        layers("C after write+clear", fieldA)
        mgr()?.undo()
        await settle(400)
        layers("C after undo", fieldA)
        await type("de")
        state("C after re-typing")
        layers("C after re-typing", fieldA)
        mgr()?.undo()
        await settle(400)
        layers("C after undo of re-typing", fieldA)

        // ===== D: the textarea
        say("--- D textarea")
        await focus(.area)
        state("D floor0")
        say("D mgr===window.undoManager: \(mgr() === keyWindow()?.undoManager)")
        areaNode.text = ""
        await clearFloor("D")
        _ = GroupWatch.shared.drain()
        areaNode.text = "PROG"
        await settle(400)
        state("D after write-only")
        say("D groups(write-only)=\(GroupWatch.shared.drain())")
        layers("D after write-only", area)
        areaNode.text = ""
        await clearFloor("D2")
        await type("abc")
        state("D after typing")
        layers("D after typing", area)
        areaNode.text = "PROG"
        await settle(400)
        state("D after write")
        layers("D after write", area)
        mgr()?.undo()
        await settle(400)
        layers("D after undo", area)
        areaNode.text = ""
        await clearFloor("D3")
        await type("abc")
        areaNode.text = "PROG"
        await settle(400)
        mgr()?.removeAllActions()
        await settle(250)
        state("D after write+clear")
        mgr()?.undo()
        await settle(400)
        layers("D after clear+undo", area)
        await type("de")
        state("D after re-typing")
        mgr()?.undo()
        await settle(400)
        layers("D after undo of re-typing", area)

        // ===== E: per-field managers, focus round trip
        say("--- E scope")
        await focus(.a)
        entryA.text = ""
        await clearFloor("E")
        await type("abc")
        let mA = oid(mgr())
        state("E A typed")
        await focus(.b)
        let mB = oid(mgr())
        say("E managerA=\(mA) managerB=\(mB) same=\(mA == mB)")
        entryB.text = ""
        await clearFloor("Eb")
        await type("de")
        state("E B typed")
        await focus(.a)
        say("E back on A: manager=\(oid(mgr())) sameAsFirst=\(mA == oid(mgr()))")
        state("E back on A")
        mgr()?.undo()
        await settle(400)
        layers("E after undo on refocused A", fieldA)

        // ===== F: a write while the field is NOT focused
        say("--- F unfocused write")
        await focus(.b)
        entryA.text = "BLURWRITE"
        await settle(500)
        await focus(.a)
        state("F focused A after blurred write")
        layers("F focused A after blurred write", fieldA)
        mgr()?.undo()
        await settle(400)
        layers("F after undo", fieldA)

        // ===== P6: shake
        say("--- P6 shake")
        await focus(.a)
        entryA.text = ""
        await clearFloor("P6")
        await type("abc")
        state("P6 armed")
        layers("P6 armed", fieldA)
        // UIKit delivers a motion event to the FIRST RESPONDER and the
        // default UIResponder implementation walks it up the chain to
        // UIApplication, which is where the undo alert is presented.
        // Both entry points are tried, and the screen is captured from
        // outside by build.sh, because an alert is a THING ON SCREEN
        // and no in-process boolean is proof on its own.
        if let fr = firstResponder() {
            fr.motionBegan(.motionShake, with: nil)
            fr.motionEnded(.motionShake, with: nil)
        }
        await settle(1200)
        say("P6 after responder motionEnded: presented=\(presentedChain())")
        UIApplication.shared.motionBegan(.motionShake, with: nil)
        UIApplication.shared.motionEnded(.motionShake, with: nil)
        await settle(1500)
        say("P6 after UIApplication motionEnded: presented=\(presentedChain())")
        state("P6 after shakes")
        layers("P6 after shakes", fieldA)
        say("P6 HOLDING 12s for the screenshot")
        await settle(12000)
        say("P6 presented(after hold)=\(presentedChain())")
        layers("P6 end", fieldA)

        say("done")
    }

    /// Whatever is presented over the root — an alert shows up here.
    func presentedChain() -> String {
        guard var vc = keyWindow()?.rootViewController else { return "no root" }
        var out = [oid(vc)]
        while let p = vc.presentedViewController {
            var d = oid(p)
            if let alert = p as? UIAlertController {
                d +=
                    "(title=\"\(alert.title ?? "")\" msg=\"\(alert.message ?? "")\" actions=\(alert.actions.map { $0.title ?? "" }))"
            }
            out.append(d)
            vc = p
        }
        return out.joined(separator: " -> ")
    }
}

/// kaya's own delegate shape: a UIResponder subclass, adapted in.
final class ProbeAppDelegate: UIResponder, UIApplicationDelegate {}

struct ProbeApp: App {
    @UIApplicationDelegateAdaptor(ProbeAppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { ProbeRoot() }
    }
}

_ = GroupWatch.shared
ProbeApp.main()
