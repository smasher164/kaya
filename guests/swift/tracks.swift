// The tracks scene, Swift port — guests/rust/tracks.rs,
// tools/scenes/tracks.steps.

import Foundation
import Kaya

struct Track: KayaGen {
    var number: String
    var title: String
    var artist: String
    var album: String
    var art: Data
    var tint: KayaTint
}

let playlistLength = 60
let playing = 3
let names = [
    ("Blue in Green", "Miles Davis", "Kind of Blue"),
    ("So What", "Miles Davis", "Kind of Blue"),
    ("Naima", "John Coltrane", "Giant Steps"),
]

@KayaAppActor
func table(_ tx: KayaAppTx, _ tracks: KayaRecordCollection<Track>, _ id: String, _ rowId: String) -> KayaWidget {
    let table = trackEach(tx, tracks) { row in
        let line = row.row {
            row.label(row.number)
            row.row {
                let image = row.image(row.art, fit: .cover)
                row.t.setMaxWidth(image, 40)
                row.t.setMaxHeight(image, 40)
                row.t.setShape(image, .rounded)
                row.t.setA11yId(image, "art")
                row.column {
                    let title = row.label(row.title)
                    row.t.setTint(title, row.tint)
                    row.t.setA11yId(title, "name")
                    row.t.caption(row.artist)
                }
            }
            row.label(row.album)
        }
        row.t.setA11yId(line, rowId)
    }
    tx.columns(table, ["#", "Title", "Album"], .none)
    tx.setA11yId(table, id)
    return table
}

func track(_ i: Int, _ art: Data) -> Track {
    let (title, artist, album) = names[i % names.count]
    return Track(number: String(i + 1), title: title, artist: artist, album: album, art: art,
                 tint: i + 1 == playing ? .accent : .none)
}

KayaApp.run { app in
    let art = try KayaAsset("covers/cover-600.jpg").bytes
    app.build { tx in
        tx.window(title: "tracks", width: 720, height: 640)
        let album = trackCollection(tx)
        let playlist = trackCollection(tx)
        let root = tx.column(spacing: 12) { root in
            _ = table(tx, album, "album", "a")
            let long = table(tx, playlist, "tracks", "t")
            tx.setGrow(long, 1)
            return root
        }
        tx.mount(root)
        for i in 0..<names.count {
            album.insert(tx, .str("a\(i + 1)"), track(i, art))
        }
        for i in 0..<playlistLength {
            playlist.insert(tx, .str("t\(i + 1)"), track(i, art))
        }
    }
}
