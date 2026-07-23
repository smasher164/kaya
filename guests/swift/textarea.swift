// The textarea conformance scene, Swift port. See
// guests/rust/textarea.rs and tools/scenes/textarea.steps.

import Foundation

func count(_ text: String) -> String {
    text.isEmpty ? "0 lines" : "\(text.split(separator: "\n", omittingEmptySubsequences: false).filter { !($0.isEmpty && text.hasSuffix("\n")) }.count) lines"
}

let app = KayaApp()

app.build { tx in
    tx.window(title: "textarea")
    let lines = tx.signal(.str("0 lines"))

    let root = tx.column {
        let editor = tx.textarea { t, text in
            t.write(lines, .str(count(text)))
        }
        tx.label(bind: lines)  // label#0
        tx.button("clear") { t in
            t.clear(editor)
            t.focus(editor)
        }
    }
    tx.mount(root)
}

app.run()
