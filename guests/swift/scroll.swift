// The scroll conformance scene, Swift port — the viewport grows so
// the enclosing track constrains it (an unconstrained viewport hugs
// its content and nothing overflows); the bottom button, reachable
// only by scrolling, proves the scrolled-to content is live. See
// guests/rust/scroll.rs and tools/scenes/scroll.steps.

import Foundation

let app = KayaApp()

var status: KayaSignal!

app.build { tx in
    tx.window(title: "scroll")
    status = tx.signal(.str("at top"))
    let root = tx.column {
        tx.label(bind: status)  // label#0
        tx.scroll(grow: 1) {  // scroll#0
            tx.column {
                for i in 1...29 {
                    let caption = tx.signal(.str("row \(i)"))
                    tx.label(bind: caption)
                }
                tx.button(
                    "bottom",
                    onClick: { inner in  // button#0
                        inner.write(status, .str("bottom clicked"))
                    })
            }
        }
    }
    tx.mount(root)
}

app.run()
