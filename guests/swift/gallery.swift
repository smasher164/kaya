// The gallery scene from Swift: a row with a checkbox and its status
// label, and a row with a slider and its volume label. Both controls
// own their state and report each change; the app answers by writing
// the paired signal — the entry's uncontrolled contract, with a bool
// and a Double.

import Foundation

/// A 2x2 RGB PNG (red/green over blue/white), 75 bytes: the first
/// binary asset, embedded as source per the include_str! doctrine —
/// scenes carry their inputs, no runtime file I/O.
let testPNG = Data([
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 2,
    0, 0, 0, 2, 8, 2, 0, 0, 0, 253, 212, 154, 115, 0, 0, 0, 18, 73, 68, 65,
    84, 120, 156, 99, 248, 207, 192, 192, 0, 194, 12, 255, 129, 0, 0, 31, 238,
    5, 251, 11, 217, 104, 139, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
])

let app = KayaApp()

// The construction sugar: constructors carry their handlers,
// result-builder containers take their children, and the build closure
// reads as the tree.
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
            // The programmatic write: fans out to the control and
            // must NOT come back as a volume occurrence.
            tx.button("quarter") { t in
                t.write(pos, .f64(0.25))
            }
        }
        tx.row {
            // The content-buffer row: a valid 2x2 PNG decodes and
            // reports its size, and deliberately invalid bytes read
            // 0x0 — decode failure is the placeholder class, never a
            // crash, on every backend.
            tx.image(testPNG)
            tx.image(Data("not an image".utf8))
        }
    }
    tx.mount(root)
}

app.run()
