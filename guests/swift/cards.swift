// The cards scene, Swift port — guests/rust/cards.rs,
// tools/scenes/cards.steps.

import Foundation
import Kaya

struct Playlist: KayaGen {
    var name: String
    var selected: Bool
    var symbol: KayaSymbol
}

let cards = [("card1", "Daily Mix 1"), ("card2", "Daily Mix 2"), ("card3", "Discover Weekly")]
// The third card is taller, so the row's cards take its height (M16 (1)).
let tall = "card3"
// Cut at two lines with the platform's ellipsis (M16 (2)).
let blurb = "Fresh picks every Monday, from the artists you play the most and the ones they listen to"
let library = [("p1", "Liked Songs"), ("p2", "Late Night Jazz"), ("p3", "Focus")]

@discardableResult
func card(_ tx: KayaAppTx, _ status: KayaSignal, _ id: String, _ name: String) -> KayaWidget {
    tx.column(filled: .neutral, onActivate: { t in
        t.write(status, .str("opened: \(name)"))
    }) { card in
        tx.label(name)
        tx.caption("Made for you")
        if id == tall {
            let blurbLabel = tx.caption(blurb)
            tx.setMaxLines(blurbLabel, 2)
            tx.setA11yId(blurbLabel, "blurb")
        }
        tx.setA11yId(card, id)
        return card
    }
}

KayaApp.run { app in
    app.build { tx in
        tx.window(title: "cards", width: 520, height: 520)
        let status = tx.signal(.str("opened: none"))
        let playlists = playlistCollection(tx)
        // A section hidden by a When and an empty For take no space (M16 (3)).
        let hidden = tx.signal(.bool(false))
        let empty = playlistCollection(tx)
        let root = tx.column(spacing: 16) { root in
            let grid = tx.grid(columns: 1, spacing: 12) { grid in
                for (id, name) in cards { card(tx, status, id, name) }
                return grid
            }
            tx.setColumnsAuto(grid, 140)
            tx.setA11yId(grid, "cards")
            tx.setA11yId(tx.button("More") { t in
                t.within(grid) { () -> KayaWidget in card(t, status, "card4", "Release Radar") }
            }, "more")
            tx.setA11yId(tx.label(bind: status), "status")
            _ = tx.when(hidden) { t in t.label("never shown") }
            playlistEach(tx, empty) { row in
                row.row { row.label(row.name) }
            }
            tx.setA11yId(tx.label("end"), "end")
            playlistEach(tx, playlists) { row in
                var item: KayaNodeHandle?
                row.row {
                    item = row.row {
                        row.label(row.name)
                    }
                    let play = row.t.button("Play")
                    row.t.setSymbol(play, row.symbol)
                    row.t.setA11yId(play, "go")
                    app.onClick(play) { t, keys in
                        guard case .str(let played) = keys[0] else { return }
                        for (key, _) in library {
                            playlists.patch(t, .str(key)).set(\.symbol, key == played ? .pause : .play)
                        }
                    }
                }
                guard let item else { return }
                row.t.setA11yId(item, "lib")
                row.t.setSelected(item, row.selected)
                row.t.onActivate(item) { t, keys in
                    guard case .str(let picked) = keys[0] else { return }
                    for (key, _) in library {
                        playlists.patch(t, .str(key)).set(\.selected, key == picked)
                    }
                }
            }
            return root
        }
        tx.mount(root)
        for (key, name) in library {
            playlists.insert(tx, .str(key), Playlist(name: name, selected: false, symbol: .play))
        }
    }
}
