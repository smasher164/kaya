// The confirm conformance scene, Swift port — the modal-alert
// grammar via named arguments (the request/result grammar's first
// client): one button re-shows a two-action alert; the three rounds
// take the three answer paths (action 0, action 1,
// KAYA_ALERT_CHOICE_CANCEL — every platform-native dismissal), and
// the status label records each result. The result handler rides
// the REQUEST (a trailing closure, the widget-handler precedent)
// and retires with its one answer; ids are binding-allocated. See
// guests/rust/confirm.rs and tools/scenes/confirm.steps.

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
                // The result handler rides the request and retires
                // with its one answer; ids are binding-allocated —
                // no counter plumbing.
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
                // A different dialog, a different handler: the
                // association is the registration itself.
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
