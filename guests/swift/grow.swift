// The grow conformance scene, Swift port — see guests/rust/grow.rs for
// the full rationale. Every child of the column and of the row is a
// grower, so each split is exactly weight/Σweight: 1,2,1 divide the
// column 25/50/25 and the row's 1,3 divide its width 25/75. The
// harness (KAYA_SELFTEST=grow) asserts both splits, root-fills, and
// that the textarea TAKES the track its weight earned, byte-for-byte
// against every other language and backend.
//
// The `grow:` argument is the declarative spelling; tx.setGrow is the
// dynamic path this scene has no reason to use.

import Foundation

let app = KayaApp()

app.build { tx in
    let probe = tx.signal(.str("grow probe"))
    let one = tx.signal(.str("one"))

    let root = tx.column {
        tx.label(bind: probe, grow: 1)  // label#0
        tx.textarea(grow: 2)  // textarea#0
        tx.row(grow: 1, spacing: 12) {
            tx.label(bind: one, grow: 1)  // label#1
            tx.button("three", grow: 3)
        }
    }
    tx.mount(root)
}

app.run()
