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
// THE MISS IS A QUESTION, AND SWIFT IS WHY IT HAS TO BE. A miss traps
// here — `fatalError` does not unwind — so this guest could not catch
// one however it was written. `KayaAsset.missSentence` hands back the
// same string the trap would carry, without trapping, and that is the
// one shape all nine languages can observe.
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

app.build { tx in
    tx.window(title: "assets", width: 480, height: 360)

    let mark = KayaAsset(markName)
    let font = KayaAsset(fontName)
    // Read both while the handles are open; the close is explicit, as
    // the typeface scene's is.
    let markBytes = mark.bytes
    let fontLength = font.bytes.count
    mark.close()
    font.close()

    let census = firstLine(KayaAsset.missSentence(missingName))
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

// Nothing to drive: every observation is a read of the first mount.
app.run()
