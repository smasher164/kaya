// The accessibility conformance scene from Swift: setA11yId/setA11yLabel
// read back out of the PLATFORM'S OWN accessibility tree, not kaya's
// model. See guests/rust/a11y.rs and tools/scenes/a11y.steps.
//
// EXACTLY ONE CONTAINER OF EACH KIND: container targets are ordinal, so
// a second row or column here renames every later one.

import Foundation

let app = KayaApp()

try app.build { tx in
    // THE MARK THE APP'S OWN BUILD SHIPPED, opened OUT HERE because a
    // container's builder closure does not throw. `try` and no `catch`,
    // as in identity.swift — a mark the build did not ship is a wall at
    // startup, and the assets scene is where the catch is exercised.
    let mark = try KayaAsset("images/a11y-logo.png")
    let form = tx.column {
        // Caption-bearing controls: identified, but deliberately NOT
        // labelled. The platform must speak the caption.
        let save = tx.button("Save")
        tx.setA11yId(save, "save")
        tx.setA11yHint(save, "save the draft")
        let details = tx.checkbox("Details")
        tx.setA11yId(details, "details")
        tx.setA11yHint(details, "show more detail")
        tx.setA11yId(tx.button("Reset"), "reset")
        tx.setA11yId(tx.label("Ready"), "status")
        // Caption-less controls: an app MUST name these, and the tree
        // must report the authored name.
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
        // The bytes never enter this guest's heap — the handle goes
        // straight to the blob channel.
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
    }
    // Safe here: the blob table already holds its own reference.
    mark.close()
    tx.setA11yId(form, "form")
    tx.setA11yLabel(form, "Form")
    tx.mount(form)
}

app.run()
