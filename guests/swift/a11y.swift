// The accessibility conformance scene from Swift: the two universal
// props (setA11yId, setA11yLabel) and the verb that reads them back out
// of the PLATFORM'S OWN accessibility tree rather than kaya's model.
//
// Every widget kind appears, and exactly one container of each
// container kind — the props are universal, and container targets are
// stable only while a scene keeps one of each. See guests/rust/a11y.rs
// for the full note; the byte-frozen contract is
// tools/scenes/a11y.steps.

import Foundation

/// A 2x2 RGB PNG (red/green over blue/white), 75 bytes: the gallery
/// scene's asset, embedded as source per the include_str! doctrine —
/// scenes carry their inputs, no runtime file I/O.
let testPNG = Data([
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 2,
    0, 0, 0, 2, 8, 2, 0, 0, 0, 253, 212, 154, 115, 0, 0, 0, 18, 73, 68, 65,
    84, 120, 156, 99, 248, 207, 192, 192, 0, 194, 12, 255, 129, 0, 0, 31, 238,
    5, 251, 11, 217, 104, 139, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
])

let app = KayaApp()

app.build { tx in
    let form = tx.column {
        // Caption-bearing controls: identified, but deliberately NOT
        // labelled. The platform must speak the caption.
        tx.setA11yId(tx.button("Save"), "save")
        tx.setA11yId(tx.checkbox("Details"), "details")
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
        let logo = tx.image(testPNG)
        tx.setA11yId(logo, "logo")
        tx.setA11yLabel(logo, "Logo")
        // The two CHOICE kinds: their options carry captions, the
        // choice itself does not.
        let color = tx.select(["Red", "Green"])
        tx.setA11yId(color, "color")
        tx.setA11yLabel(color, "Color")
        let size = tx.radio(["Small", "Large"])
        tx.setA11yId(size, "size")
        tx.setA11yLabel(size, "Size")
        // Containers are GROUPS to an assistive client, and naming one
        // is how an app declares it a group.
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
    tx.setA11yId(form, "form")
    tx.setA11yLabel(form, "Form")
    tx.mount(form)
}

app.run()
