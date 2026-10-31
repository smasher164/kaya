// The hidden-rows scene, Swift port — guests/rust/hiderows.rs,
// tools/scenes/hiderows.steps (docs/hidden-plan.md).

import Foundation
import Kaya

struct HiderowsNote: KayaGen {
    var title: String
    var unmatched: Bool
}

struct HiderowsFile: KayaGen {
    var name: String
    var size: String
    var unmatched: Bool
}

let hiderowsNotes = ["alpha", "beta", "gamma"]

func hiderowsFileName(_ i: Int) -> String { String(format: "file %03d", i) }

// Swift's String.contains("") is FALSE where every other language's
// substring test is true: the empty query matches every row.
func hiderowsMatches(_ text: String, _ query: String) -> Bool { query.isEmpty || text.contains(query) }

KayaApp.run { app in
    app.build { tx in
        tx.window(title: "hiderows")
        let notes = hiderowsNoteCollection(tx)
        let files = hiderowsFileCollection(tx)
        let two = tx.signal(.bool(false))

        let root = tx.column { root in
            let findNotes = tx.search { t, query in
                for title in hiderowsNotes {
                    notes.patch(t, .str(title)).set(\.unmatched, !hiderowsMatches(title, query))
                }
            }
            tx.setPlaceholder(findNotes, "Find notes")
            tx.setA11yId(findNotes, "find_notes")
            let list = hiderowsNoteEach(tx, notes) { row in
                let line = row.t.row {
                    row.label(row.title)
                    row.t.setA11yId(row.t.entry(), "note")
                }
                row.t.setHidden(line, row.unmatched)
            }
            tx.setA11yId(list, "notes")
            let tiles = tx.grid(columns: 2) { tiles in
                tx.label("one")
                tx.setHidden(tx.label("two"), two)
                tx.label("three")
                return tiles
            }
            tx.setA11yId(tiles, "tiles")
            tx.setA11yId(tx.checkbox("Hide two") { t, on in t.write(two, .bool(on)) }, "hide_two")
            let findFiles = tx.search { t, query in
                for i in 0..<300 {
                    let name = hiderowsFileName(i)
                    files.patch(t, .str(name)).set(\.unmatched, !hiderowsMatches(name, query))
                }
            }
            tx.setPlaceholder(findFiles, "Find files")
            tx.setA11yId(findFiles, "find_files")
            let table = hiderowsFileEach(tx, files) { row in
                let line = row.t.row {
                    row.label(row.name)
                    row.label(row.size)
                }
                row.t.setHidden(line, row.unmatched)
            }
            tx.setA11yId(table, "files")
            tx.setGrow(table, 1)
            tx.columns(table, ["Name", "Size"], .none)
            return root
        }
        tx.mount(root)
        for title in hiderowsNotes {
            notes.insert(tx, .str(title), HiderowsNote(title: title, unmatched: false))
        }
        for i in 0..<300 {
            let name = hiderowsFileName(i)
            files.insert(tx, .str(name), HiderowsFile(name: name, size: "\(i) KB", unmatched: false))
        }
    }
}
