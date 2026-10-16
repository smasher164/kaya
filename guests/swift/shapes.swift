// The shapes scene, Swift port — guests/rust/shapes.rs,
// tools/scenes/shapes.steps.

import Foundation
import Kaya

struct Person: KayaGen {
    var name: String
    var face: Data
    var phase: KayaImagePhase
}

KayaApp.run { app in
    let art = try KayaAsset("covers/cover-600.jpg").bytes
    let photo = try KayaAsset("images/photo.jpg").bytes
    app.build { tx in
        tx.window(title: "shapes", width: 420, height: 360)
        let people = personCollection(tx)
        let root = tx.column(spacing: 16) { root in
            tx.row(spacing: 16) { _ in
                for (id, shape) in [("rect", KayaShape.rect), ("rounded", .rounded), ("circle", .circle)] {
                    let image = tx.image(art, fit: .cover, maxWidth: 48, maxHeight: 48)
                    tx.setShape(image, shape)
                    tx.setA11yId(image, id)
                }
                let wide = tx.image(photo, maxWidth: 48, maxHeight: 48)
                tx.setShape(wide, .circle)
                tx.setA11yId(wide, "wide")
            }
            personEach(tx, people) { row in
                row.row {
                    let face = row.image(row.face, fit: .cover, phase: row.phase)
                    row.t.setMaxWidth(face, 48)
                    row.t.setMaxHeight(face, 48)
                    row.t.setShape(face, .circle)
                    row.t.setA11yId(face, "avatar")
                    row.label(row.name)
                }
            }
            return root
        }
        tx.mount(root)
        people.insert(tx, .str("a1"), Person(name: "Ada", face: Data(), phase: .loading))
    }
}
