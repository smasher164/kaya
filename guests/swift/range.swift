// The range scene, Swift port — guests/rust/range.rs,
// tools/scenes/range.steps, docs/range-plan.md.

import Foundation
import Kaya

struct Clip: KayaGen {
    var name: String
    var trimIn: Double
    var trimOut: Double
}

// The harness's own slider spelling (crates/kaya/src/harness.rs).
func spelled(_ v: Double) -> String {
    var s = String(format: "%.6f", v)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s
}

KayaApp.run { app in
    var commits = 0

    app.build { tx in
        let liveText = tx.signal(.str("live: 2 8"))
        let commitText = tx.signal(.str("commits: 0"))
        let volumeText = tx.signal(.str("volume: 0.25"))
        let clipText = tx.signal(.str("clip: none"))
        let lowSig = tx.signal(.f64(2.0))
        let highSig = tx.signal(.f64(8.0))
        let clips = clipCollection(tx)

        let root = tx.column { root in
            tx.label(bind: liveText)  // label#0
            tx.label(bind: commitText)  // label#1
            tx.label(bind: volumeText)  // label#2
            tx.label(bind: clipText)  // label#3
            let trim = tx.range(  // range#0
                min: 0.0, max: 10.0, step: 0.5, tickSpacing: 1.0, minGap: 1.0,
                lowLabel: "In", highLabel: "Out", bind: (low: lowSig, high: highSig),
                onChange: { tx, low, high in
                    tx.write(liveText, .str("live: \(spelled(low)) \(spelled(high))"))
                },
                onCommit: { tx, low, high in
                    commits += 1
                    tx.write(
                        commitText, .str("commits: \(commits) at \(spelled(low)) \(spelled(high))"))
                })
            tx.setA11yLabel(trim, "Trim")
            tx.setA11yId(trim, "trim")
            let playhead = tx.slider(min: 0.0, max: 10.0, value: 5.0)  // slider#0
            tx.setA11yLabel(playhead, "Playhead")
            let volume = tx.slider(  // slider#1
                min: 0.0, max: 1.0, value: 0.25, step: 0.25, axis: .vertical,
                onChange: { tx, v in tx.write(volumeText, .str("volume: \(spelled(v))")) })
            tx.setA11yLabel(volume, "Volume")
            tx.setA11yId(volume, "volume")
            tx.button("reset") { tx in  // button#0
                // Must NOT come back as a move or a commit.
                tx.write(lowSig, .f64(1.0))
            }
            tx.button("late") { tx in  // button#1
                // Crosses a high thumb the user moved; the core clamps it (docs/range-plan.md §3).
                tx.write(lowSig, .f64(6.0))
            }
            for row in clips.rows {
                row.label(row.name)
                let clip = row.range(
                    min: 0.0, max: 10.0, low: row.trimIn, high: row.trimOut, step: 0.5,
                    minGap: 1.0,
                    onCommit: { tx, keys, low, high in
                        guard case .str(let key) = keys[0] else { return }
                        tx.write(clipText, .str("clip \(key): \(spelled(low)) \(spelled(high))"))
                    })
                row.t.setA11yId(clip, "clip")
            }
            return root
        }
        tx.mount(root)

        clips.insert(tx, .str("a"), Clip(name: "a", trimIn: 1.0, trimOut: 4.0))
        clips.insert(tx, .str("b"), Clip(name: "b", trimIn: 3.0, trimOut: 7.0))
    }
}
