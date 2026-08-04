// UndoProbe round 3 (iOS simulator) — WHICH STACK the shake gesture
// drives, decided by a discriminator instead of by the alert's title.
//
// Round 2 could not prove it: `accessibilityActivate` on the alert's
// Undo button returned false, so the button was never pressed and the
// only evidence was the title string ("Undo Typing"), which is an
// inference. This round asks the question a different way — arm ONLY
// the WINDOW's undoManager, with a name of its own, and shake:
//
//   K1 field stack EMPTY, window manager armed "App Step"
//      -> an alert titled "Undo App Step" means the shake walks the
//         responder chain (fall-through, mac's behaviour).
//      -> NO alert means the shake sees the focused text's private
//         manager and nothing else.
//   K2 field stack FULL, window manager armed "App Step"
//      -> the title says which one wins when both have content.
//   K3 the alert's own view tree, so a later session knows what is
//      tappable if it needs to drive the button for real.
//
// THROWAWAY. Nothing builds it but build3.sh beside it.
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

struct ProbeRoot: View {
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 14) {
            TextField("", text: Binding(get: { entryA.text }, set: { entryA.text = $0 }))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
                .focused($focused)
        }
        .padding(24)
        .onAppear {
            focused = true
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
final class Runner {
    static let shared = Runner()
    var appAction = "unfired"

    func settle(_ ms: UInt64 = 250) async {
        try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }
    func mgr() -> UndoManager? { firstResponder()?.undoManager }
    func alert() -> UIAlertController? {
        var vc = keyWindow()?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc as? UIAlertController
    }
    func type(_ s: String) async {
        guard let ki = firstResponder() as? UIKeyInput else { return }
        for ch in s {
            ki.insertText(String(ch))
            await settle(90)
        }
    }
    func armWindow(_ name: String) {
        appAction = "unfired"
        keyWindow()?.undoManager?.removeAllActions()
        keyWindow()?.undoManager?.registerUndo(withTarget: self) { me in me.appAction = "FIRED" }
        keyWindow()?.undoManager?.setActionName(name)
    }
    func clearField() async {
        var tries = 0
        while tries < 8 {
            await settle(150)
            mgr()?.removeAllActions()
            await settle(150)
            if !(mgr()?.canUndo ?? false) { break }
            tries += 1
        }
    }
    func shake() async {
        firstResponder()?.motionBegan(.motionShake, with: nil)
        firstResponder()?.motionEnded(.motionShake, with: nil)
        await settle(1500)
    }
    func report(_ tag: String) {
        let m = mgr()
        let w = keyWindow()?.undoManager
        say(
            "\(tag) field(\(oid(m))) canUndo=\(m?.canUndo ?? false) name=\"\(m?.undoActionName ?? "")\" | window(\(oid(w))) canUndo=\(w?.canUndo ?? false) name=\"\(w?.undoActionName ?? "")\" | text=\"\(entryA.text)\""
        )
        if let a = alert() {
            say("\(tag) ALERT title=\"\(a.title ?? "")\" actions=\(a.actions.map { $0.title ?? "" })")
        } else {
            say("\(tag) no alert")
        }
    }

    func run() async {
        await settle(1200)
        say("iOS \(UIDevice.current.systemVersion)")

        // ===== K1: only the WINDOW's manager has anything
        say("--- K1 field empty, window armed")
        entryA.text = ""
        await clearField()
        armWindow("App Step")
        await settle(300)
        report("K1 before")
        await shake()
        report("K1 after shake")

        // ===== K2: both have something
        say("--- K2 field full, window armed")
        if alert() != nil {
            // dismiss without choosing, so K2 starts clean
            alert()?.dismiss(animated: false)
            await settle(600)
        }
        armWindow("App Step")
        await type("abc")
        await settle(300)
        report("K2 before")
        await shake()
        report("K2 after shake")

        // ===== K3: what is in the alert, for anyone who must tap it
        if let a = alert() {
            say("--- K3 alert tree")
            func walk(_ v: UIView, _ d: Int) {
                if d > 5 { return }
                let isControl = v is UIControl
                say(
                    "K3 \(String(repeating: "  ", count: d))\(oid(v)) control=\(isControl) label=\"\(v.accessibilityLabel ?? "")\" traits=\(v.accessibilityTraits.rawValue)"
                )
                for s in v.subviews { walk(s, d + 1) }
            }
            walk(a.view, 0)
        }
        say("K3 HOLDING 10s for the screenshot")
        await settle(10000)
        report("K3 end")
        say("done")
    }
}

final class ProbeAppDelegate: UIResponder, UIApplicationDelegate {}

struct ProbeApp: App {
    @UIApplicationDelegateAdaptor(ProbeAppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { ProbeRoot() }
    }
}

ProbeApp.main()
