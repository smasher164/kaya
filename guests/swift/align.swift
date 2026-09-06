// The align scene, Swift port — guests/rust/align.rs,
// tools/scenes/align.steps.

import Foundation

// A 2x64 PNG: the tall no-baseline child.
let tallPNG = Data([
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x40,
    0x08, 0x02, 0x00, 0x00, 0x00, 0xbf, 0x44, 0x31, 0x14, 0x00, 0x00, 0x00,
    0x12, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x08, 0x08, 0x8a, 0x02,
    0x22, 0x86, 0x51, 0x6a, 0x68, 0x52, 0x00, 0x43, 0x32, 0x7e, 0x01, 0x31,
    0x01, 0x41, 0x7c, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae,
    0x42, 0x60, 0x82,
])

let app = KayaApp()

app.build { tx in
    let probe = tx.signal(.str("align probe"))
    let base = tx.signal(.str("base"))
    let anchor = tx.signal(.str("anchor"))
    let fit = tx.signal(.str("fit"))
    let plain = tx.signal(.str("plain probe"))

    let root = tx.column(align: .stretch) {
            let centered = tx.column(align: .center) {  // column#1: the center trio
                tx.label(bind: probe)  // label#0
                tx.button("mid")
                let baseline = tx.row(align: .baseline) {  // the baseline trio
                    tx.label(bind: base)  // label#1
                    tx.button("tick")
                    tx.image(tallPNG)
                }
                tx.setA11yId(baseline, "baseline")
            }
            tx.setA11yId(centered, "centered")
            tx.row {  // row#1: the stretch pair's host
                tx.label(bind: anchor)  // label#2
                // column#2
                let fitcol = tx.column(grow: 1, align: .stretch) {
                    tx.label(bind: fit)  // label#3
                    tx.button("wide")
                }
                tx.setA11yId(fitcol, "fitcol")
            }
            // row@plain: NO align, so the core's centre default is what
            // the scene reads
            let plainRow = tx.row {
                tx.setA11yId(tx.label(bind: plain), "plainlabel")  // label#4
                tx.image(tallPNG)
            }
            tx.setA11yId(plainRow, "plain")
            // column@knobs: NO align; fill opts one child out of its
            // default and one in
            let knobs = tx.column {
                let optout = tx.textarea()
                tx.setFill(optout, false)
                tx.setA11yId(optout, "optout")
                let fills = tx.button("fills")
                tx.setFill(fills, true)
                tx.setA11yId(fills, "fills")
            }
            tx.setA11yId(knobs, "knobs")
        }
    tx.setA11yId(root, "root")
    tx.mount(root)
}

app.run()
