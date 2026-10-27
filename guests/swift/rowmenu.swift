// The row menu scene, Swift port — guests/rust/rowmenu.rs,
// tools/scenes/rowmenu.steps (docs/media-player-plan.md M26).

import Foundation
import Kaya

struct RowmenuEntry: KayaGen {
    var title: String
    var mark: String
    var plain: Bool
}

KayaApp.run { app in
    app.build { tx in
        tx.window(title: "rowmenu")
        let status = tx.signal(.str("ready"))
        let hide = tx.signal(.bool(true))
        let notes = rowmenuEntryCollection(tx)
        let files = rowmenuEntryCollection(tx)
        func toggle(
            _ c: KayaRecordCollection<RowmenuEntry>, _ on: String, _ off: String,
            _ did: String, _ undid: String
        ) -> (KayaAppTx, [KayaValue]) throws -> Void {
            { t, keys in
                guard case .str(let key) = keys[0] else { return }
                let set = c.items(t).first { $0.key == .str(key) }?.value.mark == on
                c.patch(t, .str(key)).set(\.mark, set ? off : on).set(\.plain, !set)
                t.write(status, .str("\(set ? did : undid) \(key)"))
            }
        }
        let open: (KayaAppTx, [KayaValue]) throws -> Void = { t, keys in
            guard case .str(let key) = keys[0] else { return }
            t.write(status, .str("opened \(key)"))
        }
        let star = tx.item("Star", onActivate: toggle(notes, "Star", "Unstar", "starred", "unstarred"))
        let noteMenu = tx.contextCatalog(items: [star, tx.separator(), tx.item("Open", onActivate: open)])
        let pin = tx.item("Pin", onActivate: toggle(files, "Pin", "Unpin", "pinned", "unpinned"))
        let fileMenu = tx.contextCatalog(items: [pin, tx.separator(), tx.item("Open", onActivate: open)])

        let root = tx.column { root in
            tx.label(bind: status)
            _ = tx.row { pair in
                _ = tx.column { trio in
                    tx.setA11yId(tx.label("A"), "va")
                    let b = tx.label("B")
                    tx.setA11yId(b, "vb")
                    tx.setHidden(b, hide)
                    tx.setA11yId(tx.label("C"), "vc")
                    return trio
                }
                tx.setA11yId(tx.button("Show B", onClick: { t in t.write(hide, .bool(false)) }), "show")
                return pair
            }
            rowmenuEntryEach(tx, notes) { row in
                let line = row.t.row {
                    row.t.column {
                        row.t.setA11yId(row.label(row.title), "title")
                        let flag = row.t.caption(row.mark)
                        row.t.setA11yId(flag, "flag")
                        row.t.setHidden(flag, row.plain)
                        row.t.setA11yId(row.t.caption(row.title), "foot")
                    }
                }
                row.t.setA11yId(line, "note")
                row.t.contextMenu(line, noteMenu)
                row.t.contextLabel(line, star, row.mark)
            }
            let table = rowmenuEntryEach(tx, files) { row in
                let line = row.t.row {
                    row.label(row.title)
                }
                row.t.setA11yId(line, "file")
                row.t.contextMenu(line, fileMenu)
                row.t.contextLabel(line, pin, row.mark)
            }
            tx.setGrow(table, 1)
            tx.columns(table, ["Name"], .none)
            return root
        }
        tx.mount(root)
        for (key, title, mark) in [("a", "apples", "Star"), ("b", "bread", "Unstar")] {
            notes.insert(tx, .str(key), RowmenuEntry(title: title, mark: mark, plain: mark == "Star"))
        }
        for (key, title, mark) in [("x", "x.txt", "Pin"), ("y", "y.txt", "Unpin")] {
            files.insert(tx, .str(key), RowmenuEntry(title: title, mark: mark, plain: mark == "Pin"))
        }
    }
}
