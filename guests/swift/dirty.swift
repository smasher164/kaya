// The dirty-state conformance scene, Swift port — see guests/rust/dirty.rs
// for the full rationale. Unsaved work as window chrome
// (docs/dirty-plan.md): one boolean beside `title:` and `vetoClose:`, and
// the backend spells its platform's own affordance — the dot in the close
// button on macOS, a leading `*` in the rendered caption on Windows, a
// bullet in the GTK header bar, nothing on the phones, which have none.
//
// TWO DECLARATIONS, ON PURPOSE. An edit writes the document AND says
// `dirty: true`; saving writes it back and says `dirty: false`. kaya does
// not watch your signals and guess — "the document has unsaved changes" is
// a statement only the app can make, and the window construct is where it
// makes it.
//
// AND THE MARK ARMS NOTHING. The close attempt fires the veto class this
// window already opted into, the app opens its own dialog, and cancelling
// keeps the window with the mark still up. That flow is composed here out
// of parts that predate this prop — which is the whole reason `dirty:` is
// presentation and nothing else.

import Foundation

let app = KayaApp()

var doc: KayaSignal!
var status: KayaSignal!

app.build { tx in
    // `dirty:` and `vetoClose:` are orthogonal — either can be set without
    // the other, on every platform. This window takes both because it is
    // an editor: it owns its close so it can ask. The handler rides the
    // window construct (handlers scope to the thing that declares them),
    // so it can only ever mean this surface's close.
    tx.window(
        title: "dirty", vetoClose: true,
        onCloseRequested: { tx in
            // Nothing has closed: the veto class says so. An editor with
            // unsaved work asks; a clean one agrees at once.
            tx.showAlert(
                title: "unsaved changes",
                message: "the document has unsaved changes",
                actions: ["Discard"], cancel: "Keep Editing"
            ) { tx, choice in
                if choice == KAYA_ALERT_CHOICE_CANCEL {
                    // Answering a dialog is not saving: the mark stays up.
                    tx.write(status, .str("kept editing"))
                } else {
                    // Agreeing destroys the surface, which for the PRIMARY
                    // window is the process itself — so the scene answers
                    // cancel and this arm stays the honest spelling of
                    // "yes, close it" rather than a step.
                    tx.destroyWindow(0)
                }
            }
        })

    doc = tx.signal(.str("notes"))
    status = tx.signal(.str("saved"))
    let root = tx.column {
        tx.label(bind: doc)  // label#0
        tx.label(bind: status)  // label#1
        tx.button("edit") { tx in  // button#0
            // ONE TRANSACTION, THREE STATEMENTS. Neither implies the
            // other: writing the document does not mark the window, and
            // marking it does not write anything.
            tx.write(doc, .str("notes and a line"))
            tx.write(status, .str("unsaved"))
            tx.window(dirty: true)
        }
        tx.button("save") { tx in  // button#1
            tx.write(status, .str("saved"))
            // The mark comes DOWN as well as up.
            tx.window(dirty: false)
        }
    }
    tx.mount(root)
}

app.run()
