import AppKit
import Foundation

// Hazard strings. Kaya's authoritative text is a Rust String (UTF-8);
// AppKit's NSRange counts UTF-16 code units. Every location below is
// stated in UTF-16 units, with the byte offset noted in the label.
let cases: [(String, String)] = [
    ("EMOJI  ab<U+1F600>cd", "ab\u{1F600}cd"),
    ("COMBIN abe<U+0301>cd", "abe\u{0301}cd"),
    ("ZWJ    ab<family>cd",  "ab\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}cd"),
    ("CJK    ab<3 han>cd",   "ab\u{65E5}\u{672C}\u{8A9E}cd"),
]

func hex(_ s: String) -> String { s.utf8.map { String(format: "%02x", $0) }.joined(separator: " ") }

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)   // NO window, no dock tile, nothing on screen

for (label, text) in cases {
    print("### \(label)")
    let ns = text as NSString
    print("  utf8_bytes=\(text.utf8.count) utf16_units=\(ns.length) scalars=\(text.unicodeScalars.count) graphemes=\(text.count)")

    let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    tv.string = text
    // Force a layout pass without a window, so anything that would
    // explode on a bad range explodes here.
    tv.layoutManager?.ensureLayout(for: tv.textContainer!)
    tv.textLayoutManager?.ensureLayout(for: tv.textLayoutManager!.documentRange)

    // 1. SELECT with a location INSIDE the first non-ASCII unit run.
    for loc in [2, 3, 4] {
        tv.setSelectedRange(NSRange(location: loc, length: 1))
        let got = tv.selectedRange
        // the documented snapping primitive AppKit uses for user selection
        let proposed = tv.selectionRange(forProposedRange: NSRange(location: loc, length: 1),
                                         granularity: .selectByCharacter)
        print("  select(loc:\(loc),len:1) -> readback {\(got.location),\(got.length)}  selectionRangeForProposed -> {\(proposed.location),\(proposed.length)}")
    }

    // 2. rangeOfComposedCharacterSequence — Foundation's own snap
    for at in [2, 3, 4] where at < ns.length {
        let r = ns.rangeOfComposedCharacterSequence(at: at)
        print("  rangeOfComposedCharacterSequence(at:\(at)) -> {\(r.location),\(r.length)}")
    }

    // 3. HIGHLIGHT with a range that splits the first non-ASCII unit run
    let bad = NSRange(location: 2, length: 1)
    tv.textStorage?.beginEditing()
    tv.textStorage?.addAttribute(.backgroundColor, value: NSColor.yellow, range: bad)
    tv.textStorage?.endEditing()
    tv.layoutManager?.ensureLayout(for: tv.textContainer!)
    var eff = NSRange(location: 0, length: 0)
    let attr = tv.textStorage?.attribute(.backgroundColor, at: 2, effectiveRange: &eff)
    print("  highlight{2,1} accepted=\(attr != nil) effectiveRange={\(eff.location),\(eff.length)}  (no exception)")
    // What does the attributed substring of a split range decode to?
    let sub = ns.substring(with: bad)
    print("  substring{2,1} utf8=[\(hex(sub))] wellformed=\(sub.unicodeScalars.allSatisfy { $0.properties.isAlphabetic || true } && !sub.utf8.contains(0xEF))")

    // 4. REVEAL with a split range
    tv.scrollRangeToVisible(NSRange(location: 3, length: 0))
    print("  scrollRangeToVisible{3,0} -> no exception")

    // 5. Out of bounds: what AppKit does with a range past the end
    let over = NSRange(location: ns.length + 5, length: 1)
    let clamped = tv.selectionRange(forProposedRange: over, granularity: .selectByCharacter)
    print("  selectionRangeForProposed{\(over.location),1} (past end) -> {\(clamped.location),\(clamped.length)}")
    print("")
}

// A lone surrogate cannot even be spelled as a Swift String: prove the
// boundary that DESIGN.md claims ("the FFI repairs it before it exists").
let loneHigh = String(UnicodeScalar(0xD83D) ?? "?")
print("### lone surrogate as Swift String scalar -> \(loneHigh.unicodeScalars.map { String(format: "U+%04X", $0.value) })")
print("DONE")
