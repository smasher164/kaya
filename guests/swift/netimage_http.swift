// The network images scene over HTTP, Swift port — guests/rust/netimage_http.rs,
// tools/scenes/netimage_http.steps: the row image helper fetching from the
// lane's media server with its default URLSession fetch.

import Foundation
import Kaya

struct Song: KayaGen {
    var title: String
    var artURL: String
    var art: Data
    var phase: KayaImagePhase
}

let covers = ["covers/cover-600.jpg", "covers/cover-320.jpg", "covers/cover-1000.jpg"]

KayaApp.run { app in
    guard let base = ProcessInfo.processInfo.environment["KAYA_MEDIA_URL"] else {
        fatalError(
            "kaya: the netimage_http scene reads KAYA_MEDIA_URL, the local server the lane "
                + "starts (tools/lib/media_server.py)")
    }
    var failures = 0
    let (songs, artNode, errors) = app.build { tx in
        tx.window(title: "netimage_http", width: 640, height: 560)
        let errors = tx.signal(.str("errors: 0"))
        let songs = songCollection(tx)
        var artNode: KayaNodeHandle?
        let root = tx.row { root in
            tx.setA11yId(tx.label(bind: errors), "errors")
            let table = songEach(tx, songs) { row in
                row.row {
                    let image = row.image(row.art, fit: .cover, phase: row.phase)
                    row.t.setMaxWidth(image, 20)
                    row.t.setMaxHeight(image, 20)
                    row.t.setA11yId(image, "art")
                    artNode = image
                    row.label(row.title)
                }
            }
            tx.columns(table, ["Art", "Title"], .none)
            tx.setGrow(table, 1)
            return root
        }
        tx.mount(root)
        for (key, path) in [
            ("missing", "status/404/"), ("broken", "status/500/"),
            ("junk", "covers/README.md"), ("slow", "trickle/covers/cover-600.jpg"),
        ] {
            songs.insert(
                tx, .str(key),
                Song(title: key, artURL: "\(base)/\(path)", art: Data(), phase: .loading))
        }
        for i in 0..<12 {
            songs.insert(
                tx, .str(String(format: "a%02d", i)),
                Song(
                    title: "Track \(i)", artURL: "\(base)/\(covers[i % 3])", art: Data(),
                    phase: .loading))
        }
        return (songs, artNode!, errors)
    }

    let images = KayaRowImages(app, songs, url: \.artURL, art: \.art, phase: \.phase)
    images.onError { tx, _, _ in
        failures += 1
        tx.write(errors, .str("errors: \(failures)"))
    }
    images.attach(artNode)
}
