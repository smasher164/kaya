// The text-ranges conformance scene from Swift: the three primitives an
// editor cannot write for itself — HIGHLIGHT a set of ranges, SELECT
// one, REVEAL one — driven by a search this file writes in six lines.
// See guests/rust/ranges.rs and tools/scenes/ranges.steps.
//
// WHAT SWIFT ADDS TO THE PORT, and it is the whole reason this file is
// not a transcription: Swift is the only guest language whose strings
// are indexed by NEITHER bytes nor an integer. `range(of:)` hands back
// `Range<String.Index>`, kaya's ranges are UTF-8 byte offsets, and the
// two conversions an author reaches for first — `distance(from:to:)`
// over Characters, and `utf16Offset(in:)` — are both SIX EARLY on this
// document and both silent. So the app hands kaya the ranges it already
// has, `in:` the string they index, and the binding converts
// (kayaByteRange in bindings/swift/KayaApp.swift). The document opens
// with a CJK word for exactly this reason: every match sits six bytes
// further along than it sits in UTF-16, and the scene's frozen offsets
// say so.
//
// WHAT EACH LEG PROVES, in the order the script runs them:
//   * a set of three matches decorated at once, read back out of the
//     platform's own accessibility tree;
//   * one of them selected, likewise;
//   * the third REVEALED — asserted `offscreen` first, so the leg
//     cannot pass on a document that happened to fit;
//   * a user's keystroke DROPPING the declared set (D2: ranges are
//     app-owned and never tracked across an edit);
//   * a `select_range` REFUSED because the user is mid-composition
//     (D4), which is the one thing on this surface a backend is
//     expected not to do.

import Foundation

/// The document, frozen — the same bytes as every other language's
/// guest, because the offsets the script asserts are byte offsets into
/// it. Three occurrences of `alpha` and nothing else containing that
/// substring; forty short lines, so the last match is far below a
/// 240x96 viewport and REVEAL has something to do.
///
/// A `"""` literal and not a `\n`-joined array: what a multi-line
/// literal contains is exactly what a reader sees, which is the property
/// that matters when a byte count is part of the contract (813 bytes,
/// 807 UTF-16 code units). Swift strips the newline after the opening
/// delimiter and the closing delimiter's indentation, and nothing else.
let doc0 = """
    line 00: 日本語 preface
    line 01: gamma kappa
    line 02: alpha beta gamma
    line 03: epsilon theta
    line 04: zeta nu
    line 05: eta zeta
    line 06: theta lambda
    line 07: iota delta
    line 08: kappa iota
    line 09: alpha eta theta
    line 10: mu eta
    line 11: nu mu
    line 12: beta epsilon
    line 13: gamma kappa
    line 14: delta gamma
    line 15: epsilon theta
    line 16: zeta nu
    line 17: eta zeta
    line 18: theta lambda
    line 19: iota delta
    line 20: kappa iota
    line 21: lambda beta
    line 22: mu eta
    line 23: nu mu
    line 24: beta epsilon
    line 25: gamma kappa
    line 26: delta gamma
    line 27: epsilon theta
    line 28: zeta nu
    line 29: eta zeta
    line 30: theta lambda
    line 31: iota delta
    line 32: kappa iota
    line 33: lambda beta
    line 34: mu eta
    line 35: nu mu
    line 36: beta epsilon
    line 37: alpha iota kappa
    line 38: delta gamma
    line 39: the last line
    """

let needle = "alpha"

/// THE WHOLE SEARCH. Literal, forward, non-overlapping — Foundation's
/// own range search, yielding the `Range<String.Index>` values Swift
/// hands out everywhere, which is what kaya's range verbs take. An
/// editor that wants case folding, word boundaries or a regex dialect
/// writes those here, in the app, where its users can be told what they
/// mean.
///
/// `.literal` is not decoration: without it Foundation compares by
/// canonical equivalence, so the search's own notion of a match would
/// differ from the document's bytes — the last thing a scene about
/// offsets wants.
func findAll(_ text: String, _ needle: String) -> [Range<String.Index>] {
    var hits: [Range<String.Index>] = []
    var from = text.startIndex
    while let hit = text.range(of: needle, options: .literal, range: from..<text.endIndex) {
        hits.append(hit)
        from = hit.upperBound
    }
    return hits
}

let app = KayaApp()

// The app's own copy of the document, which is the ONLY authority on
// what the offsets mean. It advances on every edit, exactly as an
// editor's buffer does — and a `String.Index` is only meaningful against
// the string it came from, which is why every range call below names
// this one.
var doc = doc0

app.build { tx in
    tx.window(title: "ranges")
    let status = tx.signal(.str("0 matches"))

    // The handle the four buttons need. A widget parents into its
    // container AT CREATION, so the editor is built inside the column
    // body like every other child and rides out through this var.
    var editor: KayaWidget! = nil

    let root = tx.column {
        editor = tx.textarea { t, text in
            doc = text
            // THE SEARCH RESULTS ARE STALE AND THE APP SAYS SO. kaya has
            // already dropped the decorations — a declared set is bound
            // to the text it was declared against — and this is the app
            // agreeing rather than being told: an editor whose document
            // moved has to search again before it can claim anything
            // about where the matches are.
            t.write(status, .str("0 matches"))
        }
        // The editor, seeded with the document the app opened. The a11y
        // id is not decoration: every range assertion reads the
        // platform's accessibility tree, and the id is how a leg finds
        // this control there.
        tx.setText(editor, doc0)
        tx.setA11yId(editor, "doc")
        tx.setA11yLabel(editor, "Document")
        tx.label(bind: status)  // label#0
        tx.row {
            tx.button("find") { t in  // button#0
                let hits = findAll(doc, needle)
                t.highlightRanges(editor, hits, in: doc)
                // The second match, so a leg can tell the selection
                // apart from "the first thing found".
                if hits.count > 1 {
                    t.selectRange(editor, hits[1], in: doc)
                }
                t.write(status, .str("\(hits.count) matches"))
            }
            tx.button("reveal last") { t in  // button#1
                if let last = findAll(doc, needle).last {
                    t.revealRange(editor, last, in: doc)
                }
            }
            tx.button("focus editor") { t in  // button#2
                t.focus(editor)
            }
            tx.button("select first") { t in  // button#3
                if let first = findAll(doc, needle).first {
                    t.selectRange(editor, first, in: doc)
                }
            }
        }
    }
    tx.mount(root)
}

app.run()
