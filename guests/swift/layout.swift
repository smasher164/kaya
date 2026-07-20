// The layout scene, Swift port — the native-default observation
// vehicle; see guests/rust/layout.rs for the axes it stresses. The two
// label expects (KAYA_SELFTEST=layout) only prove the tree built; the
// scene asserts no geometry — container targets index by creation
// order, which legitimately differs per language. The grow contract is
// asserted in the grow scene instead.

import Foundation

let app = KayaApp()

app.build { tx in
    let probe = tx.signal(.str("Layout probe"))
    let tail = tx.signal(.str("tail"))
    let mixed = tx.signal(.str("mixed"))
    let nested = tx.signal(.str("nested"))
    let deep = tx.signal(.str("deep"))

    let root = tx.column {
        tx.label(bind: probe)  // label#0

        // Main-axis free space: three unequal children with leftover
        // room.
        tx.row {
            tx.button("A")
            tx.button("longer")
            tx.label(bind: tail)  // label#1
        }

        // Cross-axis alignment: three different intrinsic heights, one
        // grower filling the leftover row width.
        tx.row {
            tx.checkbox("check")
            tx.label(bind: mixed)  // label#2
            tx.slider(min: 0.0, max: 1.0, value: 0.5, grow: 1)
        }

        // Proportional grow: two growers of unequal weight in one row.
        tx.row {
            tx.slider(min: 0.0, max: 1.0, value: 0.25, grow: 1)
            tx.slider(min: 0.0, max: 1.0, value: 0.75, grow: 3)
        }

        // Nesting: a column inside the root column, a row inside that.
        tx.column {
            tx.label(bind: nested)  // label#3
            tx.row {
                tx.label(bind: deep)  // label#4
                tx.button("x")
            }
        }
    }
    tx.mount(root)
}

app.run()
