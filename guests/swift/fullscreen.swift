// The fullscreen scene, Swift port — guests/rust/fullscreen.rs,
// tools/scenes/fullscreen.steps. The app keeps its own copy of the state: a
// toggle writes !on, and the user's door moves the copy through
// onFullscreenChanged.

import Foundation
import Kaya

KayaApp.run { app in
    var on = false
    var pinged = 0
    app.build { tx in
        let asked = tx.signal(.str("windowed"))
        let user = tx.signal(.str("no change from the user"))
        let pings = tx.signal(.str("pings 0"))
        tx.window(
            title: "fullscreen",
            onFullscreenChanged: { tx, now in
                on = now
                tx.write(
                    user,
                    .str(now ? "the user turned fullscreen on" : "the user turned fullscreen off"))
            })

        let root = tx.column { root in
            tx.label(bind: asked)  // label#0
            tx.label(bind: user)  // label#1
            tx.label(bind: pings)  // label#2
            tx.button("toggle fullscreen") { tx in  // button#0
                on = !on
                tx.window(fullscreen: on)
                tx.write(asked, .str(on ? "asked for fullscreen" : "asked for a window"))
            }
            tx.button("ping") { tx in  // button#1
                pinged += 1
                tx.write(pings, .str("pings \(pinged)"))
            }
            return root
        }
        tx.mount(root)
    }
}
