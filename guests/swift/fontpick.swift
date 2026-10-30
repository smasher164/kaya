// The font picker scene, Swift port: guests/rust/fontpick.rs,
// tools/scenes/fontpick.steps (docs/font-picker-plan.md §7).

import Foundation
import Kaya

let fontpickMono = ["Menlo", "DejaVu Sans Mono", "Cascadia Mono", "Consolas", "Courier New",
                    "Droid Sans Mono", "monospace"]
let fontpickDoc = "bold run, italic run, plain run"

func fontpickWords(_ weight: Int, _ italic: Bool, _ width: Int) -> String {
    "\(weight) \(italic ? "italic" : "upright") \(width)"
}

func fontpickLight(_ faces: [KayaFontFace]) -> (Int, Int, Int)? {
    let upright = faces.filter { !$0.italic && $0.width == 5 }.map(\.weight)
    let italic = faces.filter { $0.italic && $0.width == 5 }.map(\.weight)
    guard upright.count >= 3, upright.contains(700),
          let light = upright.first(where: { $0 < 400 && italic.contains($0) }) else { return nil }
    for (a, b) in zip(upright, upright.dropFirst()) where a >= 500 && b > a + 1 {
        return (light, a, b)
    }
    return nil
}

func fontpickUprightOnly(_ faces: [KayaFontFace]) -> Int? {
    if faces.isEmpty || faces.contains(where: \.italic) { return nil }
    return faces.first(where: { $0.width == 5 })?.weight
}

func fontpickNoBold(_ faces: [KayaFontFace]) -> Bool {
    !faces.isEmpty && faces.allSatisfy { $0.weight < 600 }
}

KayaApp.run { app in
    var ready: KayaSignal?
    var pick: KayaSignal?
    var want: [KayaSignal] = []
    var exact: KayaWidget?
    var between: KayaWidget?
    var synth: KayaWidget?
    var heavy: KayaWidget?
    var doc: KayaWidget?
    var chosen: KayaWidget?

    var queue: [String] = []
    var light: (String, (Int, Int, Int))?
    var plain: (String, Int)?
    var boldless: String?
    var mono: String?
    var asked: KayaFontChoice?

    app.onFontFamilies { t, families in
        mono = fontpickMono.first(where: { families.contains($0) })
        queue = families.reversed()
        if let mono { queue.append(mono) }
        if let next = queue.popLast() { t.listFontFaces(next) }
    }

    app.onFontFaces { t, family, faces in
        if family == mono && asked == nil {
            let face = faces.first(where: { $0.weight == 700 && !$0.italic && $0.width == 5 }) ?? faces.first
            if let face {
                asked = KayaFontChoice(family: family, weight: face.weight, italic: face.italic, width: face.width)
            }
        }
        if light == nil, let l = fontpickLight(faces) { light = (family, l) }
        if plain == nil, let w = fontpickUprightOnly(faces) { plain = (family, w) }
        if boldless == nil, fontpickNoBold(faces) { boldless = family }
        guard let light, let plain, let boldless, let ready, let exact, let between, let synth, let heavy, let doc
        else {
            if let next = queue.popLast() {
                t.listFontFaces(next)
            } else if let ready {
                t.write(ready, .str("faces: none suit"))
            }
            return
        }
        let (lf, (lw, a, b)) = light
        let (pf, pw) = plain
        t.setFamily(exact, lf)
        t.setFontWeight(exact, lw)
        t.setFamily(between, lf)
        t.setFontWeight(between, a + (b - a) / 2)
        t.setFamily(synth, pf)
        t.setFontWeight(synth, pw)
        t.setFontItalic(synth, true)
        t.setFamily(heavy, boldless)
        t.setFontWeight(heavy, 700)
        t.setFamily(doc, lf)
        t.setFontWeight(doc, lw)
        t.setDocument(doc, KayaDocument(fontpickDoc).bold(0..<4).italic(10..<16))
        t.write(want[0], .str(fontpickWords(lw, false, 5)))
        t.write(want[1], .str(fontpickWords(b, false, 5)))
        t.write(want[2], .str(fontpickWords(pw, true, 5) + " synthesized"))
        t.write(want[3], .str(fontpickWords(700, false, 5)))
        t.write(want[4], .str(fontpickWords(lw, true, 5)))
        t.write(want[6], .str(fontpickWords(700, false, 5) + " synthesized"))
        if let c = asked, let pick {
            t.write(pick, .str("\(fontpickWords(c.weight, c.italic, c.width)) \(c.family)"))
            t.write(want[5], .str(fontpickWords(c.weight, c.italic, c.width)))
        }
        t.write(ready, .str("faces: found"))
    }

    app.build { tx in
        tx.window(title: "fontpick")
        let readySignal = tx.signal(.str("faces: -"))
        ready = readySignal
        want = (0..<7).map { _ in tx.signal(.str("-")) }
        let pickSignal = tx.signal(.str("-"))
        pick = pickSignal
        let pickedSignal = tx.signal(.str("picked: -"))
        let root = tx.column { root in
            tx.setA11yId(tx.label(bind: readySignal), "ready")
            let e = tx.label("Exact")
            tx.setA11yId(e, "exact")
            exact = e
            let bw = tx.label("Between")
            tx.setA11yId(bw, "between")
            between = bw
            let s = tx.label("Slanted")
            tx.setA11yId(s, "synth")
            synth = s
            let h = tx.entry()
            tx.setA11yId(h, "heavy")
            tx.setText(h, "Heavy")
            heavy = h
            let d = tx.textarea(rich: true)
            tx.setA11yId(d, "doc")
            doc = d
            let c = tx.label("Chosen")
            tx.setA11yId(c, "chosen")
            chosen = c
            let ids = ["want_exact", "want_between", "want_synth", "want_bold", "want_italic", "want_pick",
                       "want_heavy"]
            for (signal, id) in zip(want, ids) { tx.setA11yId(tx.label(bind: signal), id) }
            tx.setA11yId(tx.label(bind: pickSignal), "pick")
            tx.setA11yId(tx.label(bind: pickedSignal), "picked")
            tx.row { _ in
                tx.setA11yId(tx.button("faces", onClick: { t in t.listFontFamilies() }), "faces")
                let open = tx.button("pick", onClick: { t in
                    _ = t.chooseFont(codeOnly: true, faces: true, initial: asked) { t, choice in
                        guard let choice, let chosen else {
                            t.write(pickedSignal, .str("picked: cancelled"))
                            return
                        }
                        t.setFamily(chosen, choice.family)
                        t.setFontWeight(chosen, choice.weight)
                        t.setFontItalic(chosen, choice.italic)
                        t.setFontWidth(chosen, choice.width)
                        let said = choice == asked ? "picked: as asked"
                            : "picked: \(fontpickWords(choice.weight, choice.italic, choice.width)) \(choice.family)"
                        t.write(pickedSignal, .str(said))
                    }
                })
                tx.setA11yId(open, "pick_button")
            }
            return root
        }
        tx.mount(root)
    }
}
