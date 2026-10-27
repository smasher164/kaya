// The code surface scene, Swift port: guests/rust/codesurface.rs,
// tools/scenes/codesurface.steps (docs/code-surface-plan.md). A textarea that
// numbers its lines, the platform's monospaced face, a family picked from the
// platform's list, a family the platform lacks, a label at twice the size.

import Foundation
import Kaya

/// Forty lines; the third wraps at every lane's width.
func codesurfaceDocument() -> String {
    var lines = [
        "// codesurface: a small source file for the gutter",
        "fn main() {",
        "    let note = \"this line is long on purpose, so that the textarea wraps it onto a second row "
            + "and the gutter has a continuation to leave unnumbered, the way every editor does\";",
    ]
    for i in 4..<40 { lines.append(String(format: "    let value_%02d = %d * 2;", i, i)) }
    lines.append("}")
    return lines.joined(separator: "\n")
}

KayaApp.run { app in
    let doc = codesurfaceDocument()
    var code: KayaWidget?
    var picked: KayaWidget?
    var listed: KayaSignal?

    app.onFontFamilies { t, families in
        let ordered = zip(families, families.dropFirst()).allSatisfy { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let word = families.isEmpty ? "families: none"
            : ordered ? "families: listed, unique, in order" : "families: out of order"
        if let listed { t.write(listed, .str(word)) }
        if let first = families.first, let picked { t.setFamily(picked, first) }
    }

    app.build { tx in
        tx.window(title: "codesurface")
        let families = tx.signal(.str("families: -"))
        listed = families
        let root = tx.column { root in
            let editor = tx.textarea()
            tx.setLineNumbers(editor, true)
            tx.setMonospaced(editor, true)
            tx.setA11yId(editor, "code")
            tx.setText(editor, doc)
            code = editor
            let plain = tx.textarea()
            tx.setA11yId(plain, "plain")
            tx.setText(plain, "plain text\nin the app's face")
            let mono = tx.label("let x = 1;")
            tx.setMonospaced(mono, true)
            tx.setA11yId(mono, "mono")
            let monoEntry = tx.entry()
            tx.setMonospaced(monoEntry, true)
            tx.setA11yId(monoEntry, "mono_entry")
            tx.setText(monoEntry, "let y = 2;")
            let missing = tx.label("missing")
            tx.setFamily(missing, "Kaya No Such Family")
            tx.setMonospaced(missing, true)
            tx.setA11yId(missing, "missing")
            let big = tx.label("Big")
            tx.setTextScale(big, 2)
            tx.setA11yId(big, "big")
            tx.setA11yId(tx.label("Plain"), "plain_label")
            tx.setA11yId(tx.label(bind: families), "families")
            let pick = tx.label("picked")
            tx.setA11yId(pick, "picked")
            picked = pick
            tx.row { _ in
                let end = tx.button("end", onClick: { t in
                    guard let code else { return }
                    t.focus(code)
                    t.selectRange(code, doc.endIndex..<doc.endIndex, in: doc)
                    t.revealRange(code, doc.endIndex..<doc.endIndex, in: doc)
                })
                tx.setA11yId(end, "end")
                let fonts = tx.button("fonts", onClick: { t in t.listFontFamilies() })
                tx.setA11yId(fonts, "fonts")
            }
            return root
        }
        tx.mount(root)
    }
}
