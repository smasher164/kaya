// The AX half of the rich-text probe (R9), in a SEPARATE PROCESS from the one
// that owns the text view — which is the only honest way to read what an
// assistive client gets. argv[1] is the held probe's pid.
//
// It walks the app element to the text area with the probe's identifier and
// reads kAXAttributedStringForRangeParameterizedAttribute over the whole text,
// printing every attribute key per run, then looks for AXLink elements.
import AppKit
import ApplicationServices

func say(_ s: String) { print("AX \(s)"); fflush(stdout) }

func copyAttr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}

func attrNames(_ e: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(e, &names) == .success else { return [] }
    return (names as? [String]) ?? []
}

func paramNames(_ e: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyParameterizedAttributeNames(e, &names) == .success else { return [] }
    return (names as? [String]) ?? []
}

func children(_ e: AXUIElement) -> [AXUIElement] {
    (copyAttr(e, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

func role(_ e: AXUIElement) -> String { (copyAttr(e, kAXRoleAttribute as String) as? String) ?? "?" }
func identifier(_ e: AXUIElement) -> String {
    (copyAttr(e, kAXIdentifierAttribute as String) as? String) ?? ""
}

func find(_ e: AXUIElement, depth: Int = 0) -> AXUIElement? {
    if identifier(e) == "richtext-probe" { return e }
    if depth > 12 { return nil }
    for c in children(e) { if let hit = find(c, depth: depth + 1) { return hit } }
    return nil
}

func describeValue(_ v: Any) -> String {
    switch v {
    case let d as [String: Any]:
        return "{" + d.keys.sorted().map { "\($0)=\(describeValue(d[$0]!))" }.joined(separator: " ") + "}"
    case let n as NSNumber: return "\(n)"
    case let s as String: return "\"\(s)\""
    case let u as URL: return "URL(\(u.absoluteString))"
    case let c as NSColor:
        let rgb = c.usingColorSpace(.sRGB)
        return rgb.map {
            String(format: "sRGB(%.2f,%.2f,%.2f)", $0.redComponent, $0.greenComponent, $0.blueComponent)
        } ?? "\(c)"
    default:
        let t = CFGetTypeID(v as CFTypeRef)
        if t == AXUIElementGetTypeID() {
            let e = v as! AXUIElement
            return "AXUIElement(role=\(role(e)) url=\(String(describing: copyAttr(e, kAXURLAttribute as String))))"
        }
        if t == CGColor.typeID {
            let c = NSColor(cgColor: (v as! CGColor))
            return describeValue(c as Any)
        }
        return "\(type(of: v)):\(v)"
    }
}

let args = CommandLine.arguments
guard args.count > 1, let pid = Int32(args[1]) else {
    say("usage: axread <pid>")
    exit(2)
}
say("AXIsProcessTrusted = \(AXIsProcessTrusted())")
let app = AXUIElementCreateApplication(pid)
guard let area = find(app) else {
    say("FAILED to find the text area with identifier richtext-probe")
    say("app children roles = \(children(app).map(role))")
    for w in children(app) {
        say("  window \(role(w)) children = \(children(w).map { "\(role($0))/\(identifier($0))" })")
    }
    exit(1)
}
say("found role=\(role(area)) identifier=\(identifier(area))")
say("attribute names = \(attrNames(area).sorted())")
say("parameterized names = \(paramNames(area).sorted())")
let value = (copyAttr(area, kAXValueAttribute as String) as? String) ?? ""
say("AXValue = \"\(value.replacingOccurrences(of: "\n", with: "\\n"))\"")
let count = (copyAttr(area, kAXNumberOfCharactersAttribute as String) as? Int) ?? 0
say("AXNumberOfCharacters = \(count)")

var range = CFRange(location: 0, length: count)
guard let rangeValue = AXValueCreate(.cfRange, &range) else { exit(3) }
var out: CFTypeRef?
let rc = AXUIElementCopyParameterizedAttributeValue(
    area, kAXAttributedStringForRangeParameterizedAttribute as CFString, rangeValue, &out)
say("AXAttributedStringForRange rc = \(rc.rawValue)")
if rc == .success, let s = out as? NSAttributedString {
    say("attributed length = \(s.length)")
    s.enumerateAttributes(in: NSRange(location: 0, length: s.length)) { attrs, r, _ in
        let sub = (s.string as NSString).substring(with: r).replacingOccurrences(of: "\n", with: "\\n")
        let keys = attrs.keys.map { $0.rawValue }.sorted()
        var parts: [String] = []
        for k in keys { parts.append("\(k)=\(describeValue(attrs[NSAttributedString.Key(k)]!))") }
        say("  run [\(r.location),\(r.location + r.length)) \"\(sub)\" -> \(parts.isEmpty ? "(none)" : parts.joined(separator: " "))")
    }
} else {
    say("no attributed string came back")
}

// AXLinks / link elements: what an assistive client can ACTIVATE, as opposed to
// an attribute it can merely read.
if let links = copyAttr(area, "AXLinks") as? [AXUIElement] {
    say("AXLinks = \(links.count)")
    for l in links {
        say("  link role=\(role(l)) url=\(String(describing: copyAttr(l, kAXURLAttribute as String))) value=\(String(describing: copyAttr(l, kAXValueAttribute as String)))")
    }
} else {
    say("AXLinks attribute absent")
}
let kids = children(area)
say("text area children = \(kids.map { "\(role($0))" })")
for k in kids where role(k) == "AXLink" {
    say("  AXLink child url=\(String(describing: copyAttr(k, kAXURLAttribute as String)))")
}
say("DONE")
