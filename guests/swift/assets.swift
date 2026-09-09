// The assets scene, Swift port — guests/rust/assets.rs,
// tools/scenes/assets.steps.

import Foundation

/// Deliberately absent, and a LEGAL name: the answer is the census sentence.
let missingName = "icons/nope.png"

let markName = "icons/kaya-mark.png"

/// SCENERY, and deliberately tiny: an image widget's intrinsic size drives
/// layout and the DECLARED mark is a user-supplied source of any size
/// (the images/ family's README). The mark is still opened.
let pictureName = "images/a11y-logo.png"

/// 111400 bytes, so a reader that truncated into a fixed buffer shows here.
let fontName = "fonts/sora-wght.ttf"

func firstLine(_ sentence: String) -> String {
    String(sentence.prefix(while: { $0 != "\n" }))
}

let app = KayaApp()

try app.build { tx in
    tx.window(title: "assets", width: 480, height: 360)

    let mark = try KayaAsset(markName)
    let picture = try KayaAsset(pictureName)
    let font = try KayaAsset(fontName)
    let markLength = mark.bytes.count
    let pictureBytes = picture.bytes
    let fontLength = font.bytes.count
    mark.close()
    picture.close()
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
    let present = markLength > 0 ? "present" : "missing"
    let sizes = tx.signal(
        .str("\(markName) \(present), \(fontName): \(fontLength) bytes, \(verdict)"))

    let root = tx.column {
        tx.label(bind: title)  // label#0
        tx.image(pictureBytes)  // image#0
        tx.label(bind: found)  // label#1
        tx.label(bind: sizes)  // label#2
    }
    tx.mount(root)
}

app.run()
