// The sections scene, Swift port — guests/rust/sections.rs,
// tools/scenes/sections.steps.

import Foundation
import Kaya

let FEED: UInt64 = 7
let ARCHIVE: UInt64 = 8
// The SIDEBAR half rides an AUX WINDOW opened only from the desktop tail's
// click, so createWindow never runs where the capability is absent.
let LIBRARY: UInt64 = 1
let SHELVES: UInt64 = 2
let LOANS: UInt64 = 3

KayaApp.run { app in
    var visitCount = 0
    app.build { tx in
        tx.window(
            title: "sections",
            sectionsPresentation: .bar)
        let visits = tx.signal(.str("archive: 0 visits"))

        // A symbol names a CONCEPT (docs/styling-plan.md D6).
        tx.addSection(FEED, title: "Feed", symbol: .home)
        tx.addSection(
            ARCHIVE, title: "Archive", symbol: .star,
            onSelected: { inner in
                visitCount += 1
                inner.write(visits, .str("archive: \(visitCount) visits"))
            })

        let feedRoot = tx.column { feedRoot in
            let ready = tx.signal(.str("feed ready"))
            tx.label(bind: ready)  // label#0
            tx.button(
                "to archive",
                onClick: { inner in  // button#0
                    // Programmatic selection: configuration, no echo.
                    inner.selectSection(ARCHIVE)
                })
            tx.button(
                "open library",
                onClick: { inner in  // button#1
                    inner.createWindow(
                        LIBRARY, title: "library",
                        sectionsPresentation: .sidebar)
                    inner.addSection(SHELVES, title: "Shelves", symbol: .search, window: LIBRARY)
                    inner.addSection(LOANS, title: "Loans", symbol: .lock, window: LIBRARY)
                    let shelvesRoot = inner.column { shelvesRoot in
                        let l = inner.signal(.str("shelves ready"))
                        inner.label(bind: l)  // label#2
                        return shelvesRoot
                    }
                    inner.mountIn(SHELVES, shelvesRoot)
                    let loansRoot = inner.column { loansRoot in
                        let l = inner.signal(.str("loans ready"))
                        inner.label(bind: l)  // label#3
                        return loansRoot
                    }
                    inner.mountIn(LOANS, loansRoot)
                })
            return feedRoot
        }
        tx.mountIn(FEED, feedRoot)

        let archiveRoot = tx.column { archiveRoot in
            tx.label(bind: visits)  // label#1
            return archiveRoot
        }
        tx.mountIn(ARCHIVE, archiveRoot)
    }
}
