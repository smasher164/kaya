// The safearea scene, Swift port — guests/rust/safearea.rs,
// tools/scenes/safearea.steps (docs/safe-area-plan.md A3, A8).

import Foundation
import Kaya

KayaApp.run { app in
    let groundBox = KayaViewbox(300.0, 200.0)

    func ground(_ d: KayaDraw, _ size: KayaViewbox) {
        d.moveTo(0.0, 0.0)
            .lineTo(size.w, 0.0)
            .lineTo(size.w, size.h)
            .lineTo(0.0, size.h)
            .close()
            .fill(.seriesFill, rule: .nonzero)
    }

    try app.build { tx in
        tx.window(title: "safearea", width: 420, height: 640)
        let caption = tx.signal(.str("inset 16"))
        let photo = try KayaAsset("images/photo.jpg")
        let root = tx.column { root in
            let picture = tx.image(photo).bleed()
            tx.setMaxHeight(picture, 160.0)
            tx.setA11yId(picture, "picture")
            tx.setA11yLabel(picture, "Photo")
            tx.setA11yId(tx.label(bind: caption), "caption")
            let inset = tx.button("No inset") { tx in
                tx.window(inset: 0.0)
                tx.write(caption, .str("inset 0"))
            }
            tx.setA11yId(inset, "inset")
            let full = tx.button("Fullscreen") { tx in
                tx.window(fullscreen: true)
                tx.write(caption, .str("fullscreen"))
            }
            tx.setA11yId(full, "full")
            let surface = tx.canvas(groundBox, grow: 1.0).bleed()
            tx.setA11yId(surface, "ground")
            tx.setA11yLabel(surface, "Ground")
            surface.onDraw { d, size in ground(d, size) }
            return root
        }
        tx.mount(root)
    }
}
