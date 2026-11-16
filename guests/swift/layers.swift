// The layers scene, Swift port — guests/rust/layers.rs,
// tools/scenes/layers.steps.

import Foundation
import Kaya

KayaApp.run { app in
    let cover = try KayaAsset("covers/cover-600.jpg").bytes
    let small = try KayaAsset("covers/cover-320.jpg").bytes
    var log = ["taps:"]
    app.build { tx in
        tx.window(title: "layers", width: 480, height: 860)
        let answered = tx.signal(.str("taps:"))
        let veiled = tx.signal(.bool(false))
        func answer(_ word: String) -> (KayaAppTx) throws -> Void {
            { tx in
                log.append(word)
                tx.write(answered, .str(log.joined(separator: " ")))
                if word == "hide" { tx.write(veiled, .bool(true)) }
            }
        }
        let root = tx.column(spacing: 16) { root in
            tx.layers(inset: 8) { stack in
                let photo = tx.image(cover, maxWidth: 320)
                tx.setA11yLabel(photo, "Kind of Blue cover")
                tx.setA11yId(photo, "photo")
                tx.row(filled: .accent) { badge in
                    tx.setA11yId(tx.label("3"), "badge_text")
                    tx.setPlace(badge, .topTrailing)
                    tx.setA11yId(badge, "badge")
                }
                tx.row(filled: .overlayFade) { caption in
                    tx.setA11yId(tx.label("Kind of Blue"), "caption_text")
                    tx.setPlace(caption, .bottom)
                    tx.setA11yId(caption, "caption")
                }
                let share = tx.button("Share", onClick: answer("share"))
                tx.setPlace(share, .bottomTrailing)
                tx.setA11yId(share, "share")
                tx.setA11yId(stack, "photostack")
            }
            tx.layers { stack in
                tx.setA11yId(tx.button("Press the base button here", onClick: answer("base")), "base")
                tx.column(align: .center) { veil in
                    tx.row(filled: .overlay) { _ in tx.label("Busy") }
                    tx.setFill(veil, true)
                    tx.setHidden(veil, veiled)
                    tx.setA11yId(veil, "busy")
                }
                tx.setA11yId(stack, "veilstack")
            }
            tx.layers { stack in
                tx.setA11yId(tx.button("Open the inbox", onClick: answer("side")), "side")
                tx.row(filled: .accent) { badge in
                    tx.label("5")
                    tx.setPlace(badge, .trailing)
                    tx.setA11yId(badge, "sidebadge")
                }
                tx.setA11yId(stack, "sidestack")
            }
            tx.layers(inset: 8) { stack in
                let photo = tx.image(small, maxWidth: 200)
                tx.setA11yLabel(photo, "Small cover")
                tx.setA11yId(photo, "smallphoto")
                tx.row(filled: .overlay) { flat in
                    tx.setA11yId(tx.label("Flat panel"), "flat_text")
                    tx.setPlace(flat, .topLeading)
                    tx.setA11yId(flat, "flat")
                }
                tx.setA11yId(stack, "flatstack")
            }
            tx.setA11yId(tx.label(bind: answered), "answered")
            tx.setA11yId(tx.button("Hide the veil", onClick: answer("hide")), "hideveil")
            return root
        }
        tx.mount(root)
    }
}
