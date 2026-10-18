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
    var selected: Bool
}

let playlistLength = 60
let playing = 3
let names = [
    ("Blue in Green", "Miles Davis", "Kind of Blue"),
    ("So What", "Miles Davis", "Kind of Blue"),
    ("Naima", "John Coltrane", "Giant Steps"),
]

@KayaAppActor
func table(
    _ tx: KayaAppTx, _ tracks: KayaRecordCollection<Track>, _ id: String, _ rowId: String,
    _ pick: @escaping (KayaAppTx, String) -> Void, _ play: @escaping (KayaAppTx, String) -> Void
) -> KayaWidget {
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
        row.t.setSelected(line, row.selected)
        row.t.onSelect(line) { t, keys in
            guard case .str(let picked) = keys[0] else { return }
            pick(t, picked)
        }
        row.t.onActivate(line) { t, keys in
            guard case .str(let picked) = keys[0] else { return }
            play(t, picked)
        }
    }
    tx.columns(table, ["#", "Title", "Album"], .none)
    tx.setA11yId(table, id)
    return table
}

func track(_ i: Int, _ art: Data) -> Track {
    let (title, artist, album) = names[i % names.count]
    return Track(number: String(i + 1), title: title, artist: artist, album: album, art: art,
                 tint: i + 1 == playing ? .accent : .none, selected: false)
}

KayaApp.run { app in
    let art = try KayaAsset("covers/cover-600.jpg").bytes
    app.build { tx in
        tx.window(title: "tracks", width: 720, height: 640)
        let album = trackCollection(tx)
        let playlist = trackCollection(tx)
        let pickedText = tx.signal(.str("picked: none"))
        let played = tx.signal(.str("played: none"))
        let select = { (t: KayaAppTx, picked: String) in
            for i in 0..<names.count {
                album.patch(t, .str("a\(i + 1)")).set(\.selected, "a\(i + 1)" == picked)
            }
            for i in 0..<playlistLength {
                playlist.patch(t, .str("t\(i + 1)")).set(\.selected, "t\(i + 1)" == picked)
            }
        }
        let pick = { (t: KayaAppTx, picked: String) in
            t.write(pickedText, .str("picked: \(picked)"))
            select(t, picked)
        }
        let play = { (t: KayaAppTx, picked: String) in
            t.write(played, .str("played: \(picked)"))
            select(t, picked)
        }
        let root = tx.column(spacing: 12) { root in
            tx.setA11yId(tx.label(bind: pickedText), "picked")
            tx.setA11yId(tx.label(bind: played), "played")
            _ = table(tx, album, "album", "a", pick, play)
            let long = table(tx, playlist, "tracks", "t", pick, play)
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
