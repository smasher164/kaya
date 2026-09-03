// The a11y scene, Swift port — guests/rust/a11y.rs, tools/scenes/a11y.steps.

import Foundation

let app = KayaApp()

try app.build { tx in
    // Opened OUT HERE because a container's builder closure does not throw;
    // `try` and no `catch`, as in identity.swift.
    let mark = try KayaAsset("images/a11y-logo.png")
    let form = tx.column {
        // Deliberately not labelled: the platform must speak the caption.
        let save = tx.button("Save")
        tx.setA11yId(save, "save")
        tx.setA11yHint(save, "save the draft")
        let details = tx.checkbox("Details")
        tx.setA11yId(details, "details")
        tx.setA11yHint(details, "show more detail")
        tx.setA11yId(tx.button("Reset"), "reset")
        tx.setA11yId(tx.label("Ready"), "status")
        let name = tx.entry()
        tx.setA11yId(name, "name")
        tx.setA11yLabel(name, "Full name")
        let notes = tx.textarea()
        tx.setA11yId(notes, "notes")
        tx.setA11yLabel(notes, "Notes")
        let volume = tx.slider(min: 0.0, max: 1.0, value: 0.5)
        tx.setA11yId(volume, "volume")
        tx.setA11yLabel(volume, "Volume")
        let loading = tx.progress(value: 0.25)
        tx.setA11yId(loading, "loading")
        tx.setA11yLabel(loading, "Loading")
        let logo = tx.image(mark)
        tx.setA11yId(logo, "logo")
        tx.setA11yLabel(logo, "Logo")
        let color = tx.select(["Red", "Green"])
        tx.setA11yId(color, "color")
        tx.setA11yLabel(color, "Color")
        let size = tx.radio(["Small", "Large"])
        tx.setA11yId(size, "size")
        tx.setA11yLabel(size, "Size")
        let cells = tx.grid(columns: 2) {
            tx.label("Name")
            tx.label("Ada")
        }
        tx.setA11yId(cells, "cells")
        tx.setA11yLabel(cells, "Cells")
        let feed = tx.scroll {
            tx.label("Item")
        }
        tx.setA11yId(feed, "feed")
        tx.setA11yLabel(feed, "Feed")
        let actions = tx.row {
            tx.setA11yId(tx.button("Cancel"), "cancel")
            tx.setA11yId(tx.button("OK"), "ok")
        }
        tx.setA11yId(actions, "actions")
        tx.setA11yLabel(actions, "Actions")
        let spoken = tx.signal(.str("Before"))
        let spokenLabel = tx.label("Spoken")
        tx.setA11yId(spokenLabel, "spoken")
        tx.setA11yLabel(spokenLabel, spoken)
        tx.setA11yId(
            tx.button("Rename", onClick: { inner in inner.write(spoken, .str("After")) }),
            "rename")
    }
    // Safe: the blob table already holds its own reference.
    mark.close()
    tx.setA11yId(form, "form")
    tx.setA11yLabel(form, "Form")
    tx.mount(form)
}

app.run()
