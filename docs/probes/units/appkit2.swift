import AppKit
import Foundation

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let text = "ab\u{1F600}cd"          // utf16: a b [D83D DE00] c d  = 6 units
let ns = text as NSString
let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
tv.string = text
tv.layoutManager?.ensureLayout(for: tv.textContainer!)

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "readback"
switch mode {
case "readback":
    // Does setSelectedRange fix a START inside the pair, an END inside
    // the pair, or a zero-length caret inside the pair?
    for r in [NSRange(location: 0, length: 3),   // end splits the pair
              NSRange(location: 3, length: 0),   // caret inside the pair
              NSRange(location: 3, length: 3),   // start inside the pair
              NSRange(location: 2, length: 1),   // start ok, end splits
              NSRange(location: 2, length: 2)] { // the whole emoji
        tv.setSelectedRange(r)
        let got = tv.selectedRange
        let sub = ns.substring(with: got)
        let bytes = sub.utf8.map { String(format: "%02x", $0) }.joined(separator: " ")
        print("  setSelectedRange{\(r.location),\(r.length)} -> {\(got.location),\(got.length)} selected_utf8=[\(bytes)]")
    }
    // And what the app would COPY out of a split selection:
    tv.setSelectedRange(NSRange(location: 2, length: 1))
    let copied = ns.substring(with: tv.selectedRange)
    print("  copy of a split selection -> scalars \(copied.unicodeScalars.map { String(format: "U+%04X", $0.value) })")
case "attr-oob":
    print("  about to addAttribute over {5,4} on a 6-unit string")
    tv.textStorage?.addAttribute(.backgroundColor, value: NSColor.yellow, range: NSRange(location: 5, length: 4))
    print("  SURVIVED")
case "select-oob":
    print("  about to setSelectedRange {5,4} on a 6-unit string")
    tv.setSelectedRange(NSRange(location: 5, length: 4))
    print("  SURVIVED readback={\(tv.selectedRange.location),\(tv.selectedRange.length)}")
case "scroll-oob":
    print("  about to scrollRangeToVisible {5,4}")
    tv.scrollRangeToVisible(NSRange(location: 5, length: 4))
    print("  SURVIVED")
case "attr-split":
    // Does a split highlight survive a LAYOUT pass (TextKit 2)?
    tv.textStorage?.addAttribute(.backgroundColor, value: NSColor.yellow, range: NSRange(location: 2, length: 1))
    tv.layoutManager?.ensureLayout(for: tv.textContainer!)
    tv.textLayoutManager?.ensureLayout(for: tv.textLayoutManager!.documentRange)
    var eff = NSRange(location: 0, length: 0)
    _ = tv.textStorage?.attribute(.backgroundColor, at: 2, effectiveRange: &eff)
    print("  SURVIVED layout, effective={\(eff.location),\(eff.length)}")
default:
    print("  unknown mode")
}
