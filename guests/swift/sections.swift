// The sections conformance scene, Swift port: two peer roots in the
// primary window's section set — presentation context, not
// lifecycle. The archive pane folds onSelected into a visit count,
// pinning the echo doctrine from both sides: the user's switch emits
// (the harness drives the real switcher), while the feed button's
// programmatic selectSection moves the selection silently. The count
// surviving switch round trips proves retention. See
// guests/rust/sections.rs and tools/scenes/sections.steps.

import Foundation

let FEED: UInt64 = 7
let ARCHIVE: UInt64 = 8

let app = KayaApp()

var visitCount = 0
var visits: KayaSignal!

app.build { tx in
    tx.windowTitle("sections")
    // The ADVISORY hint, exercised on the wire: `bar` is each
    // desktop's horizontal spelling and the phones' physics
    // regardless — no observable rides on it.
    tx.sectionsPresentation(Int64(KAYA_SECTIONS_PRESENTATION_BAR))
    visits = tx.signal(.str("archive: 0 visits"))

    tx.addSection(FEED, title: "Feed")
    tx.addSection(
        ARCHIVE, title: "Archive",
        onSelected: { inner in
            visitCount += 1
            inner.write(visits, .str("archive: \(visitCount) visits"))
        })

    let feedRoot = tx.column {
        let ready = tx.signal(.str("feed ready"))
        tx.label(bind: ready)  // label#0
        tx.button(
            "to archive",
            onClick: { inner in  // button#0
                // Programmatic selection: configuration, no echo —
                // onSelected must NOT fire (the scene asserts the
                // count holds).
                inner.selectSection(ARCHIVE)
            })
    }
    tx.mountIn(FEED, feedRoot)

    let archiveRoot = tx.column {
        tx.label(bind: visits)  // label#1
    }
    tx.mountIn(ARCHIVE, archiveRoot)
}

app.run()
