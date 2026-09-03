// The ranges scene, Swift port — guests/rust/ranges.rs,
// tools/scenes/ranges.steps.

import Foundation

/// Frozen: the same bytes as every other language's guest. The CJK word in
/// line 00 is what makes bytes and UTF-16 disagree (813 vs 807).
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

/// `.literal` is not decoration: without it Foundation compares by canonical
/// equivalence, so a match would differ from the document's bytes.
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

// A `String.Index` is meaningful only against the string it came from.
var doc = doc0

app.build { tx in
    tx.window(title: "ranges")
    let status = tx.signal(.str("0 matches"))

    // A widget parents at CREATION, so the editor rides out through this var
    // (docs/traps.md, result builders).
    var editor: KayaWidget! = nil

    let root = tx.column {
        editor = tx.textarea { t, text in
            doc = text
            // A declared set is bound to the text it was declared against (D2).
            t.write(status, .str("0 matches"))
        }
        // Every range assertion finds this control by its authored id.
        tx.setText(editor, doc0)
        tx.setA11yId(editor, "doc")
        tx.setA11yLabel(editor, "Document")
        tx.label(bind: status)  // label#0
        tx.row {
            tx.button("find") { t in  // button#0
                let hits = findAll(doc, needle)
                t.highlightRanges(editor, hits, in: doc)
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
