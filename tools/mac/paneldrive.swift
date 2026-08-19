// Probe: can an NSOpenPanel be driven end to end over the accessibility
// API — row selected, Open pressed — with no human and no synthesized
// completion? The answer decides whether the file-dialog scene needs a
// carve-out or can drive real chrome like alert_choose does.
//
// Built by hand with kaya_swiftc; not part of any lane.
//
// IT READS ALL THREE VIEW MODES, like the shipped reader: the browser's
// identifier, the element a selection goes through and the attribute
// that sets it all change with the machine-wide
// `NSGlobalDomain NSNavPanelFileListModeForOpenMode2` (1 columns,
// 2 list, 3 icons) — see docs/traps.md. validate-mac ROTATES that
// preference across the filedialog legs, so the mode this runs in is
// whatever the last run left mid-flight.
//
// The three shapes are an enum with exhaustive switches and no
// `default`, so a fourth mode fails the build until someone has written
// both how to read it and how to select in it.
import AppKit
import ApplicationServices

enum PanelShape: String, CaseIterable {
    case list = "ListView"  // AXOutline
    case icons = "IconView"  // AXList / AXCollectionList
    case columns = "ColumnView"  // AXBrowser
}

// Roles that carry CONTENT rather than structure. No lookup descends
// into one, and that is a correctness rule: in columns mode the panel
// publishes a column per path component, one of which has held 8362
// items, and every attribute read is a mach round trip — an unpruned
// walk did not finish in 45 seconds there.
let opaqueRoles: Set<String> = [
    "AXRow", "AXCell", "AXStaticText", "AXImage", "AXTextField", "AXGroup",
    "AXColumn", "AXMenuButton", "AXButton", "AXPopUpButton", "AXScrollBar",
    "AXList", "AXOutline", "AXBrowser", "AXToolbar", "AXCheckBox", "AXMenuBar",
]

func copyAttr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}

func children(_ e: AXUIElement) -> [AXUIElement] {
    (copyAttr(e, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

func identifier(_ e: AXUIElement) -> String? {
    copyAttr(e, kAXIdentifierAttribute as String) as? String
}

/// The FIRST match wins, an identifier is checked BEFORE the role is
/// pruned (the browsers and the buttons are themselves opaque roles),
/// and the walk never enters an item.
func findBy(_ e: AXUIElement, ids wanted: [String], _ depth: Int = 0) -> AXUIElement? {
    if depth > 12 { return nil }
    if let i = identifier(e), wanted.contains(i) { return e }
    if depth > 0, let role = copyAttr(e, kAXRoleAttribute as String) as? String,
        opaqueRoles.contains(role)
    {
        return nil
    }
    for c in children(e) {
        if let hit = findBy(c, ids: wanted, depth + 1) { return hit }
    }
    return nil
}

/// Every identifier published above the item level. Only the failure
/// path uses it: when the browser is a shape this probe does not know,
/// the message says what the panel DID publish instead of guessing.
func identifiers(_ e: AXUIElement, _ depth: Int = 0) -> [String] {
    if depth > 12 { return [] }
    var out: [String] = []
    if let i = identifier(e), !i.isEmpty { out.append(i) }
    if depth > 0, let role = copyAttr(e, kAXRoleAttribute as String) as? String,
        opaqueRoles.contains(role)
    {
        return out
    }
    for c in children(e) { out.append(contentsOf: identifiers(c, depth + 1)) }
    return out
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

    // From the panel's own subtree when it publishes one, matching the
    // shipped reader's path; from the application otherwise, since a
    // free-standing panel is a window and not a sheet. Printed, because
    // which one it was is the first thing a reader needs.
    let sheet = findBy(axApp, ids: ["open-panel"])
    let root = sheet ?? axApp
    print("ROOT = \(sheet == nil ? "<application>" : "open-panel")")

    // 1. Is the panel pointed where we asked? The "where" popup says so,
    //    which is the read that closes the "did we aim it right" hole.
    if let wherePopup = findBy(root, ids: ["where popup"]) {
        let v = copyAttr(wherePopup, kAXValueAttribute as String) as? String ?? "?"
        print("WHERE = \(v)")
    } else {
        print("WHERE = <not found>")
    }

    // 2. The file browser, in WHATEVER VIEW MODE the machine is in.
    guard let browser = findBy(root, ids: PanelShape.allCases.map { $0.rawValue }),
        let ident = identifier(browser), let shape = PanelShape(rawValue: ident)
    else {
        print(
            "NO FILE BROWSER — none of "
                + "\(PanelShape.allCases.map { $0.rawValue }.joined(separator: "/")) is "
                + "published. The panel published \(Set(identifiers(root)).sorted()). "
                + "The view mode is the machine-wide NSGlobalDomain "
                + "NSNavPanelFileListModeForOpenMode2 (1 columns, 2 list, 3 icons); a "
                + "fourth shape means a new PanelShape case")
        exit(1)
    }
    print("BROWSER = \(shape.rawValue)")

    // 3. Where the rows are, and where a SELECTION goes — the same
    //    element as the browser for list and icons, the LAST COLUMN for
    //    columns, since an NSBrowser selects per column and the current
    //    directory is the rightmost one.
    var container = browser
    var rows: [AXUIElement] = []
    switch shape {
    case .list:
        // AXRows FIRST, children only as the fallback: an AXOutline's
        // children are its COLUMNS as well as its rows, so a child walk
        // prints "name / size / kind / dateAdded" beside the files.
        //
        // The COLUMN HEADER IS A ROW TOO, and an identical one — role
        // AXRow, subrole AXOutlineRow — so it comes back beside the
        // files with column titles for texts. AXDisclosureLevel separates
        // them: 0 on the header, 1 on the files. A row publishing no
        // level at all is kept.
        rows = ((copyAttr(browser, kAXRowsAttribute as String) as? [AXUIElement])
            ?? children(browser))
            .filter { (copyAttr($0, "AXDisclosureLevel") as? Int) != 0 }
    case .icons:
        // A collection view with its items one AXSectionList down.
        func collect(_ e: AXUIElement, _ depth: Int) {
            if depth > 3 { return }
            for child in children(e) {
                if (copyAttr(child, kAXRoleAttribute as String) as? String) == "AXList" {
                    collect(child, depth + 1)
                } else {
                    rows.append(child)
                }
            }
        }
        collect(browser, 0)
    case .columns:
        // One AXList per path component, and ONLY THE LAST IS THIS
        // DIRECTORY. Never walk the others — see opaqueRoles.
        var columns: [AXUIElement] = []
        func hunt(_ e: AXUIElement, _ depth: Int) {
            if depth > 4 { return }
            for child in children(e) {
                switch copyAttr(child, kAXRoleAttribute as String) as? String {
                case "AXList": columns.append(child)
                case "AXScrollArea": hunt(child, depth + 1)
                default: break
                }
            }
        }
        hunt(browser, 0)
        guard let last = columns.last else {
            print("NO COLUMNS under the \(shape.rawValue) browser")
            exit(1)
        }
        container = last
        rows = children(last)
    }

    var target: AXUIElement?
    for row in rows {
        // THE NAME IS SOMETIMES THE IDENTIFIER: an icon item is an
        // AXGroup whose id is "picked.txt", whose only text lives on the
        // AXImage inside it.
        let all = texts(row) + [identifier(row)].compactMap { $0 }
        if !all.isEmpty { print("ROW texts=\(all)") }
        if all.contains(where: { $0.hasPrefix("picked") }) { target = row }
    }
    guard let row = target else {
        print("ROW NOT FOUND — the \(shape.rawValue) browser did not contain our file")
        exit(1)
    }

    // THE ATTRIBUTE IS NOT THE SAME ONE TWICE. An AXOutline takes
    // AXSelectedRows and refuses AXSelectedChildren; a collection view
    // and an NSBrowser column take AXSelectedChildren and IGNORE
    // AXSelectedRows — silently, returning success. In columns mode the
    // call that WORKS returns kAXErrorAttributeUnsupported (-25205)
    // while the selection takes, so the rc below is a note, never a
    // verdict; the completion at the bottom is the verdict.
    let attribute: String
    switch shape {
    case .list: attribute = kAXSelectedRowsAttribute as String
    case .icons, .columns: attribute = kAXSelectedChildrenAttribute as String
    }
    let sel = AXUIElementSetAttributeValue(
        container, attribute as CFString, [row] as CFArray)
    print("SELECT via \(attribute) rc=\(sel.rawValue)")

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        guard let ok = findBy(root, ids: ["OKButton"]) else {
            print("NO OKButton")
            exit(1)
        }
        let pressed = AXUIElementPerformAction(ok, kAXPressAction as CFString)
        print("PRESS OPEN rc=\(pressed.rawValue)")
    }
}
app.run()
