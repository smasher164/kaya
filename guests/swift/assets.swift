// The assets conformance scene, Swift port (docs/assets-plan.md,
// ratified 2026-08-18). The byte-frozen contract is
// tools/scenes/assets.steps.
//
// THIS ONE PROVES THE BYTES. KayaAsset has two redemptions and the
// typeface scene already covers the other — a font whose bytes go from
// the core's read straight to the platform's font machinery and never
// enter this guest's heap. Here the guest IS the consumer: it copies the
// mark out with `bytes` and hands the Data to an image, and the
// platform's own decoder answers 64x64 off the real view.
//
// THE MISS IS READ BOTH WAYS HERE, one per surface, and Swift is the
// language that has both to read. Since the throws ruling (2026-08-19) a
// miss is a `KayaAssetMiss` this guest can CATCH, so the census below
// comes out of the catch — which makes label#1's frozen bytes the wall
// on the error's payload: the sentence the guest is handed is the core's
// own, or the expectation reddens. The tail of label#2 stays on
// `KayaAsset.missSentence`, because that is the half a throw cannot
// answer: for a name that RESOLVES the query says so, having opened
// nothing. The other eight guests read both halves through the query —
// the C floor catches nothing at all, so the total answer is still the
// one shape all nine share, and this guest produces the same bytes
// either way.
//
// LINE 1 ONLY. Line 2 of that sentence names the place the core resolved
// and the route that chose it, which a bundle, a device directory and a
// repo checkout spell three different ways; line 1 is the same
// everywhere, so it is the line a scene can freeze.

import Foundation

/// The asset that is deliberately not there. A LEGAL name — relative,
/// `/`-spelled, one component deep — so what comes back is the census
/// sentence and not a name-fault one.
let missingName = "icons/nope.png"

/// The one the mark is under, and the one the census must list.
let markName = "icons/kaya-mark.png"

/// The large asset: 111400 bytes, so a reader that truncated into a
/// fixed buffer shows up here rather than passing quietly.
let fontName = "fonts/sora-wght.ttf"

/// The census half of the sentence. Empty in, empty out.
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

    // THE CATCH, which is what the throws ruling bought. The open
    // SUCCEEDING is the thing that never happens on a healthy lane, so
    // that is the arm holding a sentence saying what was measured: a
    // name the package does not carry answering to something is the fact
    // label#1 should print, and the frozen expectation reddens on it.
    var census = "\(missingName) opened"
    do {
        let gone = try KayaAsset(missingName)
        gone.close()
    } catch let miss as KayaAssetMiss {
        // The error's own sentence, unread by anything else — the same
        // bytes `KayaAsset.missSentence` would have handed over, because
        // the throw asks that very function for them.
        census = firstLine(miss.sentence)
    }
    let complaint = KayaAsset.missSentence(fontName)
    // The other arm is never taken on a healthy lane, and it shows the
    // sentence rather than a word about it: a failure here has to say
    // what was measured.
    let verdict = complaint.isEmpty ? "no complaint" : firstLine(complaint)

    let title = tx.signal(.str("assets"))
    let found = tx.signal(.str(census))
    // An Int interpolates through its own `description`, which consults
    // no locale: no separator, no padding, the same bytes as the other
    // seven languages produce.
    let sizes = tx.signal(.str("\(fontName): \(fontLength) bytes, \(verdict)"))

    let root = tx.column {
        tx.label(bind: title)  // label#0
        // THE BYTES, not the blob redemption: this scene is the
        // consumer, so what reaches the decoder is what `bytes` handed
        // back.
        tx.image(markBytes)  // image#0
        tx.label(bind: found)  // label#1
        tx.label(bind: sizes)  // label#2
    }
    tx.mount(root)
}

app.run()
