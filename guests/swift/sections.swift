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
// The SIDEBAR half of the presentation enum, in an AUX WINDOW so one
// shared scene covers BOTH arms: the primary stays `bar`, and this
// window opens from a handler only the desktop tail's click reaches —
// the phone runners cut the tail, the click never fires, and
// createWindow never runs where the capability is absent. No
// capability read needed: reachability is the gate.
let LIBRARY: UInt64 = 1
let SHELVES: UInt64 = 2
let LOANS: UInt64 = 3

let app = KayaApp()

var visitCount = 0
var visits: KayaSignal!

app.build { tx in
    // One construct carries the window's attributes (the unification
    // rule). The hint is ADVISORY: `bar` is each desktop's horizontal
    // spelling and the phones' physics regardless — no observable
    // rides on it.
    tx.window(
        title: "sections",
        sectionsPresentation: Int64(KAYA_SECTIONS_PRESENTATION_BAR))
    visits = tx.signal(.str("archive: 0 visits"))

    // THE SEMANTIC ICON (docs/styling-plan.md D6): a tab bar without
    // icons is not the platform's real thing, and the glyph that means
    // `home` differs per platform — SF Symbols spells it `house`, and
    // no shared asset would be legal anyway (SF Symbols are licensed to
    // Apple platforms only).
    tx.addSection(FEED, title: "Feed", symbol: .home)
    tx.addSection(
        ARCHIVE, title: "Archive", symbol: .star,
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
        tx.button(
            "open library",
            onClick: { inner in  // button#1
                inner.createWindow(
                    LIBRARY, title: "library",
                    sectionsPresentation: Int64(KAYA_SECTIONS_PRESENTATION_SIDEBAR))
                // The SIDEBAR arm carries symbols too: the source list
                // is where a mac app most wants them.
                inner.addSection(SHELVES, title: "Shelves", symbol: .search, window: LIBRARY)
                inner.addSection(LOANS, title: "Loans", symbol: .lock, window: LIBRARY)
                let shelvesRoot = inner.column {
                    let l = inner.signal(.str("shelves ready"))
                    inner.label(bind: l)  // label#2
                }
                inner.mountIn(SHELVES, shelvesRoot)
                let loansRoot = inner.column {
                    let l = inner.signal(.str("loans ready"))
                    inner.label(bind: l)  // label#3
                }
                inner.mountIn(LOANS, loansRoot)
            })
    }
    tx.mountIn(FEED, feedRoot)

    let archiveRoot = tx.column {
        tx.label(bind: visits)  // label#1
    }
    tx.mountIn(ARCHIVE, archiveRoot)
}

app.run()
