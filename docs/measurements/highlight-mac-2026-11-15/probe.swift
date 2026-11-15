// docs/highlight-plan.md §3, the Mac's measurement: inside a TextKit 2 layout
// fragment's draw, does a dynamic NSColor's cgColor resolve to the VIEW's
// effective appearance? Offscreen (no window), rendered by cacheDisplay in
// both appearances, and the drawn pixel read back.
import AppKit

let lightRGB: (CGFloat, CGFloat, CGFloat) = (0xF7 / 255.0, 0xE8 / 255.0, 0xAF / 255.0)
let darkRGB: (CGFloat, CGFloat, CGFloat) = (0x59 / 255.0, 0x4C / 255.0, 0x1A / 255.0)
let mark = NSColor(name: nil) { appearance in
    let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    let c = dark ? darkRGB : lightRGB
    return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
}
let markKey = NSAttributedString.Key("kaya.draw.mark")
nonisolated(unsafe) var seen: [String] = []

final class Fragment: NSTextLayoutFragment {
    override func draw(at point: CGPoint, in context: CGContext) {
        for line in textLineFragments {
            let b = line.typographicBounds
            line.attributedString.enumerateAttribute(markKey, in: line.characterRange) { v, sub, _ in
                guard let colour = v as? NSColor, sub.length > 0 else { return }
                let from = line.locationForCharacter(at: sub.location).x
                let to = line.locationForCharacter(at: NSMaxRange(sub)).x
                let cg = colour.cgColor
                let comps = (cg.components ?? []).map { String(format: "%.3f", $0) }.joined(separator: ",")
                seen.append("drawing=\(NSAppearance.currentDrawing().name.rawValue) cgColor=\(comps)")
                context.setFillColor(cg)
                context.fill(CGRect(x: point.x + b.minX + from, y: point.y + b.minY, width: to - from, height: b.height))
            }
        }
        super.draw(at: point, in: context)
    }
}
final class Delegate: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(_ m: NSTextLayoutManager, textLayoutFragmentFor l: NSTextLocation, in e: NSTextElement) -> NSTextLayoutFragment {
        Fragment(textElement: e, range: e.elementRange)
    }
}

let delegate = Delegate()
@MainActor func makeView() -> NSTextView {
    let view = NSTextView(usingTextLayoutManager: true)
    view.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
    view.textLayoutManager!.delegate = delegate
    let text = NSMutableAttributedString(string: "plain MARKED plain", attributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.textColor])
    text.addAttribute(markKey, value: mark, range: NSRange(location: 6, length: 6))
    view.textStorage!.setAttributedString(text)
    view.textLayoutManager!.ensureLayout(for: view.textLayoutManager!.documentRange)
    return view
}
@MainActor func run(_ name: NSAppearance.Name, _ given: NSTextView? = nil, _ label: String = "fresh") {
    let view = given ?? makeView()
    view.appearance = NSAppearance(named: name)
    seen = []
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    // A pixel inside the marked word, away from glyph strokes: the commonest colour in its box.
    var counts: [String: Int] = [:]
    let line = view.textLayoutManager!.textLayoutFragment(for: view.textLayoutManager!.documentRange.location)!.textLineFragments[0]
    let x0 = Int(5 + line.locationForCharacter(at: 6).x), x1 = Int(5 + line.locationForCharacter(at: 12).x)
    for x in x0..<x1 { for y in 4..<26 {
        guard let c = rep.colorAt(x: x * Int(rep.pixelsWide) / 300, y: y * Int(rep.pixelsHigh) / 60)?.usingColorSpace(.sRGB) else { continue }
        let hex = String(format: "%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
        counts[hex, default: 0] += 1
    } }
    let top = counts.sorted { $0.value > $1.value }.prefix(2).map { "\($0.key)x\($0.value)" }
    print("\(label) view=\(name.rawValue) effective=\(view.effectiveAppearance.name.rawValue) \(seen.first ?? "draw NOT called") commonest=\(top)")
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    run(.aqua)
    run(.darkAqua)
    let same = makeView()
    run(.aqua, same, "same-view")
    run(.darkAqua, same, "same-view-switched")
    run(.aqua, same, "same-view-switched-back")
}
