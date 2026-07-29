// Probe: can an NSOpenPanel be driven end to end over the accessibility
// API — row selected, Open pressed — with no human and no synthesized
// completion? The answer decides whether the file-dialog scene needs a
// carve-out or can drive real chrome like alert_choose does.
//
// Built by hand with kaya_swiftc; not part of any lane.
import AppKit
import ApplicationServices

func copyAttr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}

func children(_ e: AXUIElement) -> [AXUIElement] {
    (copyAttr(e, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

func findBy(_ e: AXUIElement, id wanted: String, _ depth: Int = 0) -> AXUIElement? {
    if depth > 12 { return nil }
    if let i = copyAttr(e, kAXIdentifierAttribute as String) as? String, i == wanted {
        return e
    }
    for c in children(e) {
        if let hit = findBy(c, id: wanted, depth + 1) { return hit }
    }
    return nil
}

// Every string under an element: a row's filename sits in a cell's
// static text, and the depth varies with the panel's view mode.
func texts(_ e: AXUIElement, _ depth: Int = 0) -> [String] {
    if depth > 6 { return [] }
    var out: [String] = []
    if let v = copyAttr(e, kAXValueAttribute as String) as? String, !v.isEmpty {
        out.append(v)
    }
    if let t = copyAttr(e, kAXTitleAttribute as String) as? String, !t.isEmpty {
        out.append(t)
    }
    for c in children(e) { out.append(contentsOf: texts(c, depth + 1)) }
    return out
}

let dir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("kaya-paneldrive")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
try? "picked bytes".write(
    to: dir.appendingPathComponent("picked.txt"), atomically: true, encoding: .utf8)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let panel = NSOpenPanel()
panel.canChooseFiles = true
panel.canChooseDirectories = false
panel.directoryURL = dir
panel.begin { r in
    let names = panel.urls.map { $0.lastPathComponent }
    print("COMPLETION response=\(r == .OK ? "OK" : "cancel") urls=\(names)")
    exit(names == ["picked.txt"] ? 0 : 1)
}

DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
    let axApp = AXUIElementCreateApplication(getpid())
    AXUIElementSetMessagingTimeout(axApp, 2.0)
    AXUIElementSetAttributeValue(
        axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(
        axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)

    // 1. Is the panel pointed where we asked? The "where" popup says so,
    //    which is the read that closes the "did we aim it right" hole.
    if let wherePopup = findBy(axApp, id: "where popup") {
        let v = copyAttr(wherePopup, kAXValueAttribute as String) as? String ?? "?"
        print("WHERE = \(v)")
    } else {
        print("WHERE = <not found>")
    }

    guard let list = findBy(axApp, id: "ListView") else {
        print("NO ListView")
        exit(1)
    }
    var target: AXUIElement?
    for row in children(list) {
        let all = texts(row)
        if !all.isEmpty { print("ROW texts=\(all)") }
        if all.contains(where: { $0.hasPrefix("picked") }) { target = row }
    }
    guard let row = target else {
        print("ROW NOT FOUND — the list did not contain our file")
        exit(1)
    }

    let sel = AXUIElementSetAttributeValue(
        list, kAXSelectedRowsAttribute as CFString, [row] as CFArray)
    print("SELECT rc=\(sel.rawValue)")

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        guard let ok = findBy(axApp, id: "OKButton") else {
            print("NO OKButton")
            exit(1)
        }
        let pressed = AXUIElementPerformAction(ok, kAXPressAction as CFString)
        print("PRESS OPEN rc=\(pressed.rawValue)")
    }
}
app.run()
