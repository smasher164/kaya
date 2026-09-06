// The gallery scene, Swift port — guests/rust/gallery.rs,
// tools/scenes/gallery.steps.

import Foundation

/// A 2x2 RGB PNG, 75 bytes, embedded as source.
let testPNG = Data([
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 2,
    0, 0, 0, 2, 8, 2, 0, 0, 0, 253, 212, 154, 115, 0, 0, 0, 18, 73, 68, 65,
    84, 120, 156, 99, 248, 207, 192, 192, 0, 194, 12, 255, 129, 0, 0, 31, 238,
    5, 251, 11, 217, 104, 139, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
])

let app = KayaApp()

app.build { tx in
    let status = tx.signal(.str("urgent: false"))
    let volume = tx.signal(.str("volume: 50%"))
    let pos = tx.signal(.f64(0.5))

    let root = tx.column {
        tx.row {
            tx.checkbox("urgent") { t, checked in
                t.write(status, .str("urgent: \(checked)"))
            }
            tx.label(bind: status)
        }
        tx.row {
            // Integer percent, so every language's formatting agrees.
            tx.slider(min: 0.0, max: 1.0, bind: pos) { t, value in
                t.write(volume, .str("volume: \(Int((value * 100).rounded()))%"))
            }
            tx.label(bind: volume)
            // A programmatic write must NOT come back as an occurrence.
            tx.button("quarter") { t in
                t.write(pos, .f64(0.25))
            }
        }
        tx.row {
            // Invalid bytes read 0x0: decode failure is the placeholder
            // class, never a crash, on every backend.
            tx.image(testPNG)
            tx.image(Data("not an image".utf8))
        }
        // The labelled row: the control's accessibility name IS the
        // label's text, with no a11yLabel of its own.
        tx.labeled("Level") {
            tx.setA11yId(tx.slider(min: 0.0, max: 1.0, value: 0.5), "level")
        }
    }
    tx.mount(root)
}

app.run()
