// The toast scene, Swift port — guests/rust/toast.rs, tools/scenes/toast.steps,
// docs/toast-plan.md §5.

import Foundation
import Kaya

struct Item: KayaGen {
    var title: String
}

KayaApp.run { app in
    var answers = 0
    var undos = 0
    var held: UInt64?

    @KayaAppActor func word(_ outcome: KayaToastOutcome) -> String {
        switch outcome {
        case .action: return "action"
        case .closed: return "closed"
        }
    }

    @KayaAppActor func titles(_ tx: KayaAppTx, _ items: KayaRecordCollection<Item>) -> String {
        let all = items.items(tx).map { $0.value.title }
        return all.isEmpty ? "empty" : all.joined(separator: ", ")
    }

    app.build { tx in
        let edit = tx.menu(
            "Edit",
            items: [
                tx.item("Undo", role: .undo),
                tx.item("Redo", role: .redo),
            ])
        let last = tx.signal(.str("no answer yet"))
        let count = tx.signal(.str("answers 0"))
        let undone = tx.signal(.str("nothing undone"))
        let rows = tx.signal(.str("Milk, Eggs, Bread"))
        let items = itemCollection(tx)

        @KayaAppActor func answered(_ text: String) -> (KayaAppTx, KayaToastOutcome) -> Void {
            return { tx, outcome in
                answers += 1
                tx.write(count, .str("answers \(answers)"))
                tx.write(last, .str("\(text): \(word(outcome))"))
            }
        }

        tx.window(
            title: "toast",
            onUndone: { tx, label, _ in
                undos += 1
                tx.write(undone, .str("undone \(undos): \(label)"))
                tx.write(rows, .str(titles(tx, items)))
            },
            menus: [edit])

        let root = tx.column { root in
            tx.label(bind: last)  // label#0
            tx.label(bind: count)  // label#1
            tx.label(bind: undone)  // label#2
            tx.label(bind: rows)  // label#3
            tx.button("show") { tx in  // button#0
                tx.showToast("Saved", onResult: answered("Saved"))
            }
            tx.button("first") { tx in  // button#1
                tx.showToast("First", action: "Open", onResult: answered("First"))
            }
            tx.button("second") { tx in  // button#2
                tx.showToast("Second", action: "Open", onResult: answered("Second"))
            }
            tx.button("delete") { tx in  // button#3
                guard let first = items.items(tx).first else { return }
                tx.undoable("delete \(first.value.title)")
                items.remove(tx, first.key)
                tx.write(rows, .str(titles(tx, items)))
                let text = "Deleted \(first.value.title)"
                tx.showToast(text, action: "Undo", undo: true, onResult: answered(text))
            }
            tx.button("hold") { tx in  // button#4
                held = tx.showToast("Working", duration: .long, onResult: answered("Working"))
            }
            tx.button("dismiss") { tx in  // button#5
                if let id = held {
                    held = nil
                    tx.dismissToast(id)
                }
            }
            for row in items.rows {
                row.row {
                    row.label(row.title)
                }
            }
            return root
        }
        tx.mount(root)
        for title in ["Milk", "Eggs", "Bread"] {
            items.insert(tx, .str(title), Item(title: title))
        }
    }
}
