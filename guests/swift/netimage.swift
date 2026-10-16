// The network images affordance scene, Swift port — guests/rust/netimage.rs,
// tools/scenes/netimage.steps. No HTTP: each "download" is a job a worker
// queue holds until a click releases it.

import Foundation
import Kaya

struct Song: KayaGen {
    var title: String
    var artURL: String
    var art: Data
    var phase: KayaImagePhase
}

enum Job: Sendable {
    case live(Data?)
    case row(key: String, url: String, bytes: Data)
}

let rowCount = 300

KayaApp.run { app in
    let post = app.post
    let worker = DispatchQueue(label: "netimage-worker")
    var live: Job?
    var pending: [(key: String, job: Job)] = []
    var needed = Set<String>()
    var ever = Set<String>()
    var twice: String?

    let covers = try ["covers/cover-600.jpg", "covers/cover-320.jpg", "covers/cover-1000.jpg"]
        .map { try KayaAsset($0).bytes }
    live = .live(covers[0])

    let (band, released, again, artNode) = app.build { tx in
        tx.window(title: "netimage", width: 820, height: 640)
        let art = tx.signal(.data(Data()))
        let phase = tx.signal(.phase(.loading))
        let band = tx.signal(.str("band: -"))
        let released = tx.signal(.str("released: none"))
        let again = tx.signal(.str("again: none"))
        let songs = songCollection(tx)
        var artNode: KayaNodeHandle?
        // The worker's side: every result comes back as a post, the
        // background route this binding has for a thread (N6).
        let receive: @KayaAppActor @Sendable (KayaAppTx, Job) -> Void = { tx, job in
            switch job {
            case .live(let bytes?):
                tx.write(art, .data(bytes))
                tx.write(phase, .phase(.shown))
            case .live(nil):
                tx.write(phase, .phase(.failed))
            case .row(let key, let url, let bytes):
                songs.patchIf(tx, .str(key), \.artURL, equals: url) {
                    $0.set(\.art, bytes).set(\.phase, .shown)
                }
            }
        }
        func release(_ batch: [Job]) {
            worker.async {
                for job in batch { post { tx in receive(tx, job) } }
            }
        }
        let root = tx.column { root in
            tx.column { _ in
                let cover = tx.image(bind: art, fit: .cover, maxWidth: 96, maxHeight: 96)
                tx.setPhase(cover, phase)
                tx.setA11yId(cover, "cover")
                tx.setA11yLabel(cover, "Cover")
                tx.row { _ in
                    tx.setA11yId(
                        tx.button("release", onClick: { _ in
                            if let job = live {
                                live = nil
                                release([job])
                            }
                        }), "release")
                    tx.setA11yId(
                        tx.button("refresh", onClick: { t in
                            live = .live(covers[1])
                            t.write(phase, .phase(.loading))
                        }), "refresh")
                }
                tx.row { _ in
                    tx.setA11yId(
                        tx.button("junk", onClick: { t in
                            t.write(art, .data(Data("not an image".utf8)))
                            t.write(phase, .phase(.shown))
                        }), "junk")
                    tx.setA11yId(
                        tx.button("fail", onClick: { t in
                            live = .live(nil)
                            t.write(art, .data(Data()))
                            t.write(phase, .phase(.loading))
                        }), "fail")
                }
                tx.row { _ in
                    tx.setA11yId(
                        tx.button("rows", onClick: { _ in
                            needed.removeAll()
                            release(pending.map(\.job))
                            pending.removeAll()
                        }), "rows")
                    tx.setA11yId(
                        tx.button("delete", onClick: { t in
                            songs.remove(t, .str("t299"))
                        }), "delete")
                    tx.setA11yId(
                        tx.button("retarget", onClick: { t in
                            pending.insert(
                                ("t298", .row(key: "t298", url: "u/298b", bytes: covers[2])), at: 0)
                            songs.patch(t, .str("t298")).set(\.artURL, "u/298b")
                        }), "retarget")
                }
                tx.setA11yId(tx.label(bind: band), "band")
                tx.setA11yId(tx.label(bind: released), "released")
                tx.setA11yId(tx.label(bind: again), "again")
            }
            let table = songEach(tx, songs) { row in
                row.row {
                    let image = row.image(row.art, fit: .cover, phase: row.phase)
                    row.t.setMaxWidth(image, 40)
                    row.t.setMaxHeight(image, 40)
                    row.t.setShape(image, .rounded)
                    row.t.setA11yId(image, "art")
                    artNode = image
                    row.label(row.title)
                }
            }
            tx.columns(table, ["Art", "Title"], .none)
            tx.setA11yId(table, "tracks")
            tx.setGrow(table, 1)
            return root
        }
        tx.mount(root)
        for i in 0..<rowCount {
            songs.insert(
                tx, .str(String(format: "t%03d", i)),
                Song(title: "Track \(i)", artURL: "u/\(i)", art: Data(), phase: .loading))
        }
        return (band, released, again, artNode!)
    }

    app.onNeeded(artNode) { tx, keys in
        guard case .str(let key) = keys[0] else { return }
        if !needed.insert(key).inserted, twice == nil { twice = key }
        ever.insert(key)
        let i = Int(key.dropFirst())!
        pending.append((key, .row(key: key, url: "u/\(i)", bytes: covers[i % 3])))
        tx.write(band, .str(ever.count < rowCount ? "band: partial" : "band: \(ever.count)"))
        tx.write(again, .str("again: \(twice ?? "none")"))
    }
    app.onReleased(artNode) { tx, keys in
        guard case .str(let key) = keys[0] else { return }
        needed.remove(key)
        pending.removeAll { $0.key == key }
        tx.write(released, .str("released: some"))
    }
}
