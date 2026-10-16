// The cards scene, Swift port — guests/rust/cards.rs,
// tools/scenes/cards.steps.

import Foundation
import Kaya

struct Playlist: KayaGen {
    var name: String
    var selected: Bool
}

let cards = [("card1", "Daily Mix 1"), ("card2", "Daily Mix 2"), ("card3", "Discover Weekly")]
let library = [("p1", "Liked Songs"), ("p2", "Late Night Jazz"), ("p3", "Focus")]

KayaApp.run { app in
    app.build { tx in
        tx.window(title: "cards", width: 520, height: 520)
        let status = tx.signal(.str("opened: none"))
        let playlists = playlistCollection(tx)
        let root = tx.column(spacing: 16) { root in
            tx.grid(columns: 3, spacing: 12) { _ in
                for (id, name) in cards {
                    tx.column(filled: .neutral, onActivate: { t in
                        t.write(status, .str("opened: \(name)"))
                    }) { card in
                        tx.label(name)
                        tx.caption("Made for you")
                        tx.setA11yId(card, id)
                    }
                }
            }
            tx.setA11yId(tx.label(bind: status), "status")
            playlistEach(tx, playlists) { row in
                let item = row.row {
                    row.label(row.name)
                }
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
            playlists.insert(tx, .str(key), Playlist(name: name, selected: false))
        }
    }
}
