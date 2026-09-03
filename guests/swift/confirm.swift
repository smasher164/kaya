// The confirm scene, Swift port — guests/rust/confirm.rs,
// tools/scenes/confirm.steps.

import Foundation

let app = KayaApp()

var status: KayaSignal!

app.build { tx in
    tx.window(title: "confirm")
    status = tx.signal(.str("no decision"))
    let root = tx.column {
        tx.label(bind: status)  // label#0
        tx.button(
            "delete",
            onClick: { inner in
                inner.showAlert(
                    title: "delete item?", message: "this cannot be undone",
                    actions: ["Delete", "Archive"], cancel: "Keep"
                ) { tx, choice in
                    let text =
                        switch choice {
                        case 0: "deleted"
                        case 1: "archived"
                        default: "kept"
                        }
                    tx.write(status, .str(text))
                }
            })
        tx.button(
            "eject",
            onClick: { inner in
                inner.showAlert(
                    title: "eject disk?", message: "it is still mounted",
                    actions: ["Eject"], cancel: "Hold"
                ) { tx, choice in
                    tx.write(status, .str(choice == 0 ? "ejected" : "held"))
                }
            })
    }
    tx.mount(root)
}

app.run()
