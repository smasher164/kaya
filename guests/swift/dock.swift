// The dock scene, Swift port — guests/rust/dock.rs,
// tools/scenes/dock.steps.

import Foundation
import Kaya

KayaApp.run { app in
    let art = try KayaAsset("covers/cover-600.jpg").bytes
    app.build { tx in
        let playing = tx.signal(.bool(true))
        tx.window(title: "dock", width: 720, height: 480)
        let player = tx.player(muted: true)
        tx.dock(40, player: player) { tx in
            let root = tx.column { root in
                _ = tx.when(playing) { t in
                    let bar = t.row {
                        let image = t.image(art)
                        t.setFit(image, .cover)
                        t.setMaxWidth(image, 40)
                        t.setMaxHeight(image, 40)
                        t.setShape(image, .rounded)
                        t.column {
                            t.label("Blue in Green")
                            t.caption("Miles Davis")
                        }
                        t.setA11yId(t.slider(min: 0, max: 1, value: 0.4), "progress")
                        t.setA11yId(t.button("Pause"), "pause")
                    }
                    t.setA11yId(bar, "bar")
                }
                return root
            }
            return (root, ())
        }
        let root = tx.column { root in
            tx.label("Library")
            tx.setA11yId(tx.button("stop") { t in t.write(playing, .bool(false)) }, "stop")
            tx.setA11yId(tx.button("play") { t in t.write(playing, .bool(true)) }, "play")
            return root
        }
        tx.mount(root)
    }
}
