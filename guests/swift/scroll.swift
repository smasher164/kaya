// The scroll scene, Swift port — guests/rust/scroll.rs,
// tools/scenes/scroll.steps.

import Foundation

let app = KayaApp()

app.build { tx in
    tx.window(title: "scroll")
    let status = tx.signal(.str("at top"))
    let root = tx.column { root in
        tx.label(bind: status)  // label#0
        tx.scroll(grow: 1) { _ in  // scroll#0
            tx.column { _ in
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
        return root
    }
    tx.mount(root)
}

app.run()
