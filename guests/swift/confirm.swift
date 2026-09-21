// The confirm scene, Swift port — guests/rust/confirm.rs,
// tools/scenes/confirm.steps.

import Foundation
import Kaya

KayaApp.run { app in
    app.build { tx in
        tx.window(title: "confirm")
        let status = tx.signal(.str("no decision"))
        let root = tx.column { root in
            tx.label(bind: status)  // label#0
            tx.button(
                "delete",
                onClick: { _ in
                    app.task {
                        let choice = await app.showAlert(
                            title: "delete item?", message: "this cannot be undone",
                            actions: ["Delete", "Archive"], cancel: "Keep")
                        let text =
                            switch choice {
                            case .action0: "deleted"
                            case .action1: "archived"
                            case .cancel: "kept"
                            }
                        app.build { tx in tx.write(status, .str(text)) }
                    }
                })
            tx.button(
                "eject",
                onClick: { _ in
                    app.task {
                        let choice = await app.showAlert(
                            title: "eject disk?", message: "it is still mounted",
                            actions: ["Eject"], cancel: "Hold")
                        app.build { tx in
                            tx.write(status, .str(choice == .action0 ? "ejected" : "held"))
                        }
                    }
                })
            return root
        }
        tx.mount(root)
    }
}
