// The typeface conformance scene, Swift port — see guests/rust/typeface.rs
// for the canonical note. The brand typeface swaps the FAMILY and leaves
// the platform's ramp alone (docs/styling-plan.md Slice 2b); it names NO
// size. The scene requests the VENDORED font's bytes so the resolved
// family is one string on every lane and no platform's fallback can
// equal it. The byte-frozen contract is tools/scenes/typeface.steps.

import Foundation

let app = KayaApp()

var status: KayaSignal!

// The fold: widget-owned state arrives as occurrences.
var draft = ""

app.build { tx in
    // BEFORE THE FIRST MOUNT, per the set-once wall. The blob registers
    // with the platform's app-font machinery and the "Sora" request
    // resolves to it — register, then resolve.
    let fontPath = ProcessInfo.processInfo.environment["KAYA_FONT_FILE"]
        ?? "guests/assets/fonts/sora-wght.ttf"
    let font: Data
    do {
        font = try Data(contentsOf: URL(fileURLWithPath: fontPath))
    } catch {
        fatalError(
            "kaya: the typeface scene needs the vendored font at \(fontPath) "
                + "(set KAYA_FONT_FILE or run from the repo root): \(error)")
    }
    tx.brandTypeface("Sora", font: font)
    tx.window(title: "typeface", width: 480, height: 360)

    let heading = tx.signal(.str("typeface"))
    status = tx.signal(.str("ready"))
    let root = tx.column {
        // The heading's text style OVERRIDES the root font, so a
        // root-only lowering leaves this label in the system face.
        let title = tx.label(bind: heading, role: .heading)  // label#0
        tx.setA11yId(title, "title")
        tx.label(bind: status)  // label#1
        // A FIELD AND A TEXTAREA, because they take the swap by DIFFERENT
        // routes: the field inherits the root font, the textarea names its
        // own ramp rung. One of them alone could not tell a half-applied
        // lowering from a whole one.
        tx.entry { _, text in draft = text }  // entry#0
        tx.textarea()  // textarea#0
        tx.button("Go") { t in  // button#0
            t.write(status, .str("clicked \(draft)"))
        }
    }
    tx.mount(root)
}

app.run()
