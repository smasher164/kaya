// The sliders scene, Swift port — guests/rust/sliders.rs,
// tools/scenes/sliders.steps, docs/slider-plan.md.

import Foundation

struct Track: KayaGen {
    var name: String
    var level: Double
}

// The harness's own slider spelling (crates/kaya/src/harness.rs).
func spelled(_ v: Double) -> String {
    var s = String(format: "%.6f", v)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s
}

let app = KayaApp()
var commits = 0

app.build { tx in
    let levelText = tx.signal(.str("value: 50"))
    let commitText = tx.signal(.str("commits: 0"))
    let volumeText = tx.signal(.str("volume: 0.5"))
    let rowText = tx.signal(.str("row: none"))
    let pos = tx.signal(.f64(50.0))
    let tracks = trackCollection(tx)

    let root = tx.column {
        tx.label(bind: levelText)  // label#0
        tx.label(bind: commitText)  // label#1
        tx.label(bind: volumeText)  // label#2
        tx.label(bind: rowText)  // label#3
        let master = tx.slider(  // slider#0
            min: 0.0, max: 100.0, step: 5.0, tickSpacing: 25.0, bind: pos,
            onChange: { tx, v in tx.write(levelText, .str("value: \(spelled(v))")) },
            onCommit: { tx, _ in
                commits += 1
                tx.write(commitText, .str("commits: \(commits)"))
            })
        tx.setA11yId(master, "master")
        tx.setA11yLabel(master, "Level")
        let volume = tx.slider(  // slider#1
            min: 0.0, max: 1.0, value: 0.5, tickSpacing: 0.25,
            onChange: { tx, v in tx.write(volumeText, .str("volume: \(spelled(v))")) })
        tx.setA11yLabel(volume, "Volume")
        tx.button("reset") { tx in  // button#0
            // Must NOT come back as a value or a commit occurrence.
            tx.write(pos, .f64(25.0))
        }
        for row in tracks.rows {
            row.label(row.name)
            let level = row.slider(
                min: 0.0, max: 100.0, value: row.level, step: 10.0,
                onCommit: { tx, keys, v in
                    guard case .str(let key) = keys[0] else { return }
                    tx.write(rowText, .str("row \(key): \(spelled(v))"))
                })
            row.t.setA11yId(level, "level")
        }
    }
    tx.mount(root)

    tracks.insert(tx, .str("a"), Track(name: "a", level: 70.0))
    tracks.insert(tx, .str("b"), Track(name: "b", level: 20.0))
}

app.run()
