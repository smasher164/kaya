// The assets scene, Swift port — guests/rust/assets.rs,
// tools/scenes/assets.steps.

import Foundation

/// Deliberately absent, and a LEGAL name: the answer is the census sentence.
let missingName = "icons/nope.png"

let markName = "icons/kaya-mark.png"

/// 111400 bytes, so a reader that truncated into a fixed buffer shows here.
let fontName = "fonts/sora-wght.ttf"

func firstLine(_ sentence: String) -> String {
    String(sentence.prefix(while: { $0 != "\n" }))
}

let app = KayaApp()

try app.build { tx in
    tx.window(title: "assets", width: 480, height: 360)

    let mark = try KayaAsset(markName)
    let font = try KayaAsset(fontName)
    let markBytes = mark.bytes
    let fontLength = font.bytes.count
    mark.close()
    font.close()

    // The open SUCCEEDING never happens on a healthy lane, so that arm says
    // what was measured.
    var census = "\(missingName) opened"
    do {
        let gone = try KayaAsset(missingName)
        gone.close()
    } catch let miss as KayaAssetMiss {
        census = firstLine(miss.sentence)
    }
    let complaint = KayaAsset.missSentence(fontName)
    let verdict = complaint.isEmpty ? "no complaint" : firstLine(complaint)

    let title = tx.signal(.str("assets"))
    let found = tx.signal(.str(census))
    // An Int interpolates through `description`, which consults no locale.
    let sizes = tx.signal(.str("\(fontName): \(fontLength) bytes, \(verdict)"))

    let root = tx.column {
        tx.label(bind: title)  // label#0
        tx.image(markBytes)  // image#0
        tx.label(bind: found)  // label#1
        tx.label(bind: sizes)  // label#2
    }
    tx.mount(root)
}

app.run()
