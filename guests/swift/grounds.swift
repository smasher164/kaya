// The grounds scene, Swift port — guests/rust/grounds.rs,
// tools/scenes/grounds.steps.

import Foundation
import Kaya

KayaApp.run { app in
    let art = try KayaAsset("covers/cover-600.jpg").bytes
    guard let colour = KayaApp.imageDominant(art) else { preconditionFailure("the cover decodes") }
    app.build { tx in
        tx.window(title: "grounds", width: 480, height: 560)
        let root = tx.column(spacing: 12) { root in
            tx.column(inset: 24) { header in
                tx.setA11yId(tx.heading("Kind of Blue"), "title")
                tx.caption("Miles Davis · 1959")
                tx.setGroundGradient(header, colour)
                tx.setA11yId(header, "header")
            }
            tx.column(inset: 24) { hero in
                tx.row(filled: .overlay) { scrim in
                    tx.label("Miles Davis")
                    tx.setA11yId(scrim, "scrim")
                }
                tx.setGroundImage(hero, art)
                tx.setA11yId(hero, "hero")
            }
            tx.column(inset: 24) { plain in
                tx.label("Plain")
                tx.setA11yId(plain, "plain")
            }
            return root
        }
        tx.mount(root)
    }
}
