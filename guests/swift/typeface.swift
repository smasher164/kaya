// The typeface scene, Swift port — guests/rust/typeface.rs,
// tools/scenes/typeface.steps.

import Foundation

let app = KayaApp()

var status: KayaSignal!

var draft = ""

try app.build { tx in
    // BEFORE THE FIRST MOUNT, per the set-once wall; the close is safe once
    // brandTypeface has registered the bytes. `try` and no `catch`.
    let font = try KayaAsset("fonts/sora-wght.ttf")
    tx.brandTypeface("Sora", font: font)
    font.close()
    tx.window(title: "typeface", width: 480, height: 360)

    let heading = tx.signal(.str("typeface"))
    status = tx.signal(.str("ready"))
    let root = tx.column {
        // The heading's text style OVERRIDES the root font: a root-only
        // lowering leaves this label in the system face.
        let title = tx.label(bind: heading, role: .heading)  // label#0
        tx.setA11yId(title, "title")
        tx.label(bind: status)  // label#1
        // Both, because they take the swap by DIFFERENT routes.
        tx.entry { _, text in draft = text }  // entry#0
        tx.textarea()  // textarea#0
        tx.button("Go") { t in  // button#0
            t.write(status, .str("clicked \(draft)"))
        }
    }
    tx.mount(root)
}

app.run()
