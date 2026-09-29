// The colour picker scene, Swift port — guests/rust/colorpicker.rs,
// tools/scenes/colorpicker.steps, docs/color-picker-plan.md.

import Foundation
import Kaya

struct Swatch: KayaGen {
    var name: String
    var fill: KayaColor
}

KayaApp.run { app in
    app.build { tx in
        let titleText = tx.signal(.str("color: none"))
        let glazeText = tx.signal(.str("alpha: none"))
        let rowText = tx.signal(.str("row: none"))
        let titleSig = tx.signal(.color(KayaColor(hex: 0x3366_99FF)))
        let swatches = swatchCollection(tx)

        let root = tx.column { root in
            tx.label(bind: titleText)  // label#0
            tx.label(bind: glazeText)  // label#1
            tx.label(bind: rowText)  // label#2
            let title = tx.colorPicker(  // color_picker#0
                bind: titleSig,
                onColor: { tx, picked in tx.write(titleText, .str("color: \(picked)")) })
            tx.setA11yLabel(title, "Title colour")
            tx.setA11yId(title, "title")
            let glaze = tx.colorPicker(  // color_picker#1
                KayaColor(hex: 0x26A2_69FF), alpha: true,
                onColor: { tx, picked in tx.write(glazeText, .str("alpha: \(picked)")) })
            tx.setA11yLabel(glaze, "Glaze")
            tx.button("reset") { tx in  // button#0
                // Must NOT come back as a Title occurrence.
                tx.write(titleSig, .color(KayaColor(hex: 0x3584_E4FF)))
            }
            for row in swatches.rows {
                row.label(row.name)
                let picker = row.colorPicker(row.fill) { tx, keys, picked in
                    guard case .str(let key) = keys[0] else { return }
                    tx.write(rowText, .str("row \(key): \(picked)"))
                }
                row.t.setA11yId(picker, "fill")
            }
            return root
        }
        tx.mount(root)

        swatches.insert(tx, .str("a"), Swatch(name: "a", fill: KayaColor(hex: 0xE661_00FF)))
        swatches.insert(tx, .str("b"), Swatch(name: "b", fill: KayaColor(hex: 0xF6D3_2DFF)))
    }
}
