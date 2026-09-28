// The scroll-to scene, Swift port — guests/rust/scrollto.rs,
// tools/scenes/scrollto.steps. The app scrolls a list of messages to a
// row by key (docs/scroll-to-plan.md), opening at the newest one before
// the first layout, jumping to one on a click, staying put on a key no
// row holds, and following its own send.

import Foundation
import Kaya

struct Message: KayaGen {
    var text: String
}

struct Frame: KayaGen {
    var name: String
}

KayaApp.run { app in
    app.build { tx in
        let messages = messageCollection(tx)
        let frames = frameCollection(tx)
        let count = tx.signal(.str("60 messages"))
        var sent = 60
        var framed = 30
        // The For's own container is what a scroll_to_row addresses
        // (docs/scroll-to-plan.md S1): the eliminator hands it back.
        var list: KayaWidget!
        var strip: KayaWidget!

        let root = tx.column { root in
            tx.setA11yId(tx.label(bind: count), "count")
            tx.row { _ in
                tx.setA11yId(
                    tx.button("jump", onClick: { t in
                        t.scrollToRow(list, .str("m10"))
                    }), "jump")
                tx.setA11yId(
                    tx.button("nowhere", onClick: { t in
                        t.scrollToRow(list, .str("m999"))
                    }), "nowhere")
                tx.setA11yId(
                    tx.button("send", onClick: { t in
                        sent += 1
                        messages.insert(
                            t, .str("m\(sent)"), Message(text: "message \(sent)"))
                        t.write(count, .str("\(sent) messages"))
                        t.scrollToRow(list, .str("m\(sent)"))
                    }), "send")
                tx.setA11yId(
                    tx.button("frame", onClick: { t in
                        t.scrollToRow(strip, .str("f10"))
                    }), "frame")
                tx.setA11yId(
                    tx.button("add frame", onClick: { t in
                        framed += 1
                        frames.insert(
                            t, .str("f\(framed)"), Frame(name: "frame \(framed)"))
                    }), "add_frame")
            }
            tx.scroll(grow: 1) { scroll in
                tx.setA11yId(scroll, "list")
                list = messageEach(tx, messages) { row in
                    row.label(row.text)
                }
                tx.setA11yId(list, "messages")
            }
            // A filmstrip that runs sideways (docs/hscroll-plan.md): the
            // same scrollToRow and followsEnd, along its own axis.
            tx.scroll(axis: .horizontal, followsEnd: true) { scroll in
                tx.setA11yId(scroll, "strip")
                strip = frameEach(tx, frames) { row in
                    row.label(row.name)
                }
                tx.setAxis(strip, .horizontal)
                tx.setA11yId(strip, "frames")
            }
            return root
        }
        tx.mount(root)

        for i in 1...30 {
            frames.insert(tx, .str("f\(i)"), Frame(name: "frame \(i)"))
        }

        for i in 1...60 {
            messages.insert(tx, .str("m\(i)"), Message(text: "message \(i)"))
        }
        tx.scrollToRow(list, .str("m60"))
    }
}
