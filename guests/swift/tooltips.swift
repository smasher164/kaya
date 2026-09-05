// The tooltips scene, Swift port — guests/rust/tooltips.rs,
// tools/scenes/tooltips.steps, docs/tooltip-plan.md.

import Foundation

struct Account: KayaGen {
    var name: String
    var note: String
}

let app = KayaApp()

app.build { tx in
    let nameHelp = tx.signal(.str("Your full name as it appears on the card"))
    let accounts = accountCollection(tx)

    let settings = tx.column {
        let save = tx.button("Save") { tx in  // button#0
            tx.write(nameHelp, .str("Your name, as saved"))
        }
        tx.setHelp(save, "Saves the draft to disk")
        tx.setA11yId(save, "save")
        let discard = tx.button("Discard")  // button#1
        tx.setHelp(discard, "Throws the draft away")
        tx.setA11yHint(discard, "discard every change")
        tx.setA11yId(discard, "discard")
        let name = tx.entry()  // entry#0
        tx.setHelp(name, nameHelp)
        tx.setA11yId(name, "fullname")
        let volume = tx.slider(min: 0.0, max: 1.0, value: 0.5)  // slider#0
        tx.setHelp(volume, "How loud the preview plays")
        tx.setA11yId(volume, "volume")
        for row in accounts.rows {
            let label = row.label(row.name)
            row.t.setHelp(label, row.note)
            row.t.setA11yId(label, row.name)
        }
    }
    tx.setHelp(settings, "The settings for this account")  // column#0
    tx.setA11yId(settings, "settings")
    tx.mount(settings)

    accounts.insert(tx, .str("a"),
                    Account(name: "a", note: "The first account, opened in March"))
    accounts.insert(tx, .str("b"),
                    Account(name: "b", note: "The second account, opened in May"))
}

app.run()
