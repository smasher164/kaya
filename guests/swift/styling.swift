// The styling scene, Swift port — guests/rust/styling.rs,
// tools/scenes/styling.steps.

import Foundation

let app = KayaApp()

var status: KayaSignal!

app.build { tx in
    // BEFORE THE FIRST MOUNT, per the set-once wall (docs/styling-plan.md).
    tx.brandAccent(0x3584E4)
    tx.window(title: "styling", width: 480, height: 360, inset: 0)

    let heading = tx.signal(.str("Sections"))
    status = tx.signal(.str("ready"))
    let root = tx.column {
        // Everything the steps read back is addressed by its AUTHORED id.
        let title = tx.heading(bind: heading)  // label#0
        tx.setA11yId(title, "title")
        tx.label(bind: status)  // label#1
        let delete = tx.button("Delete", role: .destructive) { tx in  // button#0
            tx.write(status, .str("deleted"))
        }
        tx.setA11yId(delete, "delete")
        let save = tx.button("Save", role: .prominent) { tx in  // button#1
            tx.write(status, .str("saved"))
        }
        tx.setA11yId(save, "save")
        // Declared so every backend's caption arm runs: no universal AX
        // observable, so the walls are the arms' refusals.
        tx.caption("captioned")  // label#2
    }
    tx.mount(root)
}

app.run()
