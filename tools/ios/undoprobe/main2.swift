// UndoProbe round 2 (iOS simulator) — the ROUTING and GESTURE cells that
// round 1 could only set up.
//
// What round 1 established, the J-cells this round asks and what they
// answered are docs/undo-plan.md §0; the J-labels below mark which
// reading is which.
//
// THROWAWAY. Nothing builds it but build2.sh beside it.
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
let areaNode = ProbeNode()

enum Focused: Hashable { case a, area }

struct ProbeRoot: View {
    @FocusState private var focus: Focused?
    var body: some View {
        VStack(spacing: 14) {
            TextField("", text: Binding(get: { entryA.text }, set: { entryA.text = $0 }))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
                .focused($focus, equals: .a)
            TextEditor(text: Binding(get: { areaNode.text }, set: { areaNode.text = $0 }))
                .frame(width: 240, height: 90)
                .border(Color.gray.opacity(0.4))
                .focused($focus, equals: .area)
        }
        .padding(24)
        .onAppear {
            focus = .a
            Runner.shared.setFocus = { w in focus = w }
            Task { await Runner.shared.run() }
        }
    }
}

@MainActor
func keyWindow() -> UIWindow? {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first { $0.isKeyWindow }
}

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

/// Every accessibility element under a view, flattened — J5 needs the
/// alert's "Undo" button, and an alert's buttons are not plain UIViews
/// in any documented way.
@MainActor
func axDescend(_ root: Any, _ depth: Int = 0) -> [(String, NSObject)] {
    guard depth < 8, let obj = root as? NSObject else { return [] }
    var out: [(String, NSObject)] = []
    let label = obj.accessibilityLabel ?? ""
    if !label.isEmpty { out.append((label, obj)) }
    if let v = obj as? UIView {
        for s in v.subviews { out.append(contentsOf: axDescend(s, depth + 1)) }
    }
    let n = obj.accessibilityElementCount()
    if n != NSNotFound && n > 0 {
        for i in 0..<n {
            if let e = obj.accessibilityElement(at: i) {
                out.append(contentsOf: axDescend(e, depth + 1))
            }
        }
    }
    return out
}

@MainActor
final class Runner {
    static let shared = Runner()
    var setFocus: ((Focused?) -> Void)?
    var appAction = "unfired"

    func settle(_ ms: UInt64 = 250) async {
        try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }
    func mgr() -> UndoManager? { firstResponder()?.undoManager }
    func state(_ tag: String) {
        let m = mgr()
        say(
            "\(tag) fr=\(oid(firstResponder())) mgr=\(oid(m)) canUndo=\(m?.canUndo ?? false) name=\"\(m?.undoActionName ?? "")\" model=\"\(entryA.text)\"/\"\(areaNode.text)\""
        )
    }
    func type(_ s: String) async {
        guard let ki = firstResponder() as? UIKeyInput else {
            say("!! first responder is not UIKeyInput")
            return
        }
        for ch in s {
            ki.insertText(String(ch))
            await settle(90)
        }
    }
    func focus(_ w: Focused?) async {
        setFocus?(w)
        await settle(450)
    }
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
    func presented() -> UIViewController? {
        var vc = keyWindow()?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc is UIAlertController ? vc : nil
    }

    func run() async {
        await settle(900)
        say("iOS \(UIDevice.current.systemVersion)")
        await focus(.a)
        let inputs = textInputs()
        say("inputs=\(inputs.map { oid($0) })")

        // ===== J1/J2: the route and its enablement
        say("--- J1/J2 route")
        entryA.text = ""
        await clearFloor("J1")
        let sel = Selector(("undo:"))
        if let fr = firstResponder() {
            say(
                "J2 empty: responds(undo:)=\(fr.responds(to: sel)) canPerformAction=\(fr.canPerformAction(sel, withSender: nil))"
            )
        }
        await type("abc")
        state("J1 after typing")
        if let fr = firstResponder() {
            say(
                "J2 typed: responds(undo:)=\(fr.responds(to: sel)) canPerformAction=\(fr.canPerformAction(sel, withSender: nil))"
            )
        }
        let accepted = UIApplication.shared.sendAction(sel, to: nil, from: nil, for: nil)
        await settle(450)
        say("J1 sendAction(undo:) accepted=\(accepted)")
        state("J1 after routed undo")

        // ===== J4: fall-through to the window's manager
        say("--- J4 fall-through")
        entryA.text = ""
        await clearFloor("J4")
        appAction = "unfired"
        keyWindow()?.undoManager?.removeAllActions()
        keyWindow()?.undoManager?.registerUndo(withTarget: self) { me in me.appAction = "FIRED" }
        keyWindow()?.undoManager?.setActionName("App Step")
        await settle(250)
        say(
            "J4 armed window.undoManager=\(oid(keyWindow()?.undoManager)) canUndo=\(keyWindow()?.undoManager?.canUndo ?? false)"
        )
        state("J4 field stack empty")
        if let fr = firstResponder() {
            say("J4 canPerformAction(undo:)=\(fr.canPerformAction(sel, withSender: nil))")
        }
        let acc2 = UIApplication.shared.sendAction(sel, to: nil, from: nil, for: nil)
        await settle(450)
        say("J4 empty-field routed undo accepted=\(acc2) appAction=\(appAction)")
        // and with the field's own stack full
        appAction = "unfired"
        keyWindow()?.undoManager?.removeAllActions()
        keyWindow()?.undoManager?.registerUndo(withTarget: self) { me in me.appAction = "FIRED" }
        await type("abc")
        state("J4 field stack full")
        let acc3 = UIApplication.shared.sendAction(sel, to: nil, from: nil, for: nil)
        await settle(450)
        say("J4 full-field routed undo accepted=\(acc3) appAction=\(appAction)")
        state("J4 after")
        let acc4 = UIApplication.shared.sendAction(sel, to: nil, from: nil, for: nil)
        await settle(450)
        say("J4 second routed undo accepted=\(acc4) appAction=\(appAction)")

        // ===== J6: what would take a three-finger swipe
        say("--- J6 interactions")
        for v in inputs {
            say("J6 \(oid(v)).interactions=\(v.interactions.map { String(describing: Swift.type(of: $0)) })")
            say("J6 \(oid(v)).gestureRecognizers=\(v.gestureRecognizers?.count ?? 0)")
        }
        if let w = keyWindow() {
            say("J6 window.interactions=\(w.interactions.map { String(describing: Swift.type(of: $0)) })")
            say(
                "J6 window.gestureRecognizers=\(w.gestureRecognizers?.map { String(describing: Swift.type(of: $0)) } ?? [])"
            )
        }
        if let fr = firstResponder() as? UIView {
            say(
                "J6 firstResponder.gestureRecognizers=\(fr.gestureRecognizers?.map { String(describing: Swift.type(of: $0)) } ?? [])"
            )
            var sup = fr.superview
            var d = 0
            while let s = sup, d < 4 {
                say(
                    "J6 super[\(d)] \(oid(s)) interactions=\(s.interactions.map { String(describing: Swift.type(of: $0)) })"
                )
                sup = s.superview
                d += 1
            }
        }

        // ===== J5: the shake, and WHICH STACK its Undo button drives
        say("--- J5 shake, activated through accessibility")
        entryA.text = ""
        await clearFloor("J5")
        appAction = "unfired"
        keyWindow()?.undoManager?.removeAllActions()
        keyWindow()?.undoManager?.registerUndo(withTarget: self) { me in me.appAction = "FIRED" }
        await type("abc")
        state("J5 armed")
        firstResponder()?.motionBegan(.motionShake, with: nil)
        firstResponder()?.motionEnded(.motionShake, with: nil)
        await settle(1200)
        guard let alert = presented() as? UIAlertController else {
            say("J5 !! no alert presented")
            say("done")
            return
        }
        say("J5 alert title=\"\(alert.title ?? "")\" actions=\(alert.actions.map { $0.title ?? "" })")
        let elements = axDescend(alert.view as UIView)
        say("J5 ax labels=\(elements.map { $0.0 })")
        if let undoBtn = elements.first(where: { $0.0 == "Undo" })?.1 {
            let ok = undoBtn.accessibilityActivate()
            say("J5 accessibilityActivate(Undo)=\(ok)")
        } else {
            say("J5 !! no Undo element found")
        }
        await settle(1500)
        state("J5 after activating Undo")
        say("J5 appAction=\(appAction) alertStillUp=\(presented() != nil)")

        say("done")
    }
}

final class ProbeAppDelegate: UIResponder, UIApplicationDelegate {
    /// J3: what the SYSTEM already puts in the Edit menu. kaya's own
    /// delegate overrides this same method to build its catalog.
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        let undoRedo = builder.menu(for: .undoRedo)
        say(
            "J3 system .undoRedo menu present=\(undoRedo != nil) children=\(undoRedo?.children.map { ($0 as? UICommand)?.title ?? $0.debugDescription } ?? [])"
        )
        say("J3 .edit menu present=\(builder.menu(for: .edit) != nil)")
    }
}

struct ProbeApp: App {
    @UIApplicationDelegateAdaptor(ProbeAppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { ProbeRoot() }
    }
}

ProbeApp.main()
