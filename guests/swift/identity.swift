// The identity scene, Swift port — guests/rust/identity.rs,
// tools/scenes/identity.steps.

import Foundation

let app = KayaApp()

var status: KayaSignal!

var draft = ""

try app.build { tx in
    // BEFORE THE FIRST MOUNT, per the declared-once wall; the close is safe
    // once appIdentity has registered the bytes. `try` and no `catch`.
    let icon = try KayaAsset("icons/kaya-mark.png")
    tx.appIdentity("Aurora Notes", icon: icon)
    icon.close()

    // ONE PROMOTED COMMAND, and not about commands: Windows mints its custom
    // caption from the first promotion, taking the system icon with it.
    let file = tx.menu("File", items: [tx.item("Save", symbol: .done, primary: true)])
    tx.window(title: "identity", width: 480, height: 360, menus: [file])

    let heading = tx.signal(.str("identity"))
    status = tx.signal(.str("ready"))
    let root = tx.column {
        tx.label(bind: heading)  // label#0
        tx.label(bind: status)  // label#1
        tx.entry { _, text in draft = text }  // entry#0
        tx.button("Go") { t in  // button#0
            t.write(status, .str("clicked \(draft)"))
        }
    }
    tx.mount(root)

    // DESKTOP-ONLY: KAYA_CAP_AUX_WINDOWS is unset on iOS, whose leg drops the
    // step that reads it (docs/app-identity-plan.md ruling 3). A runtime `if`.
    if KayaApp.capabilities().auxWindows {
        tx.createWindow(1, width: 360.0, height: 240.0)
        let auxRoot = tx.column {
            let caption = tx.signal(.str("no title of its own"))
            tx.label(bind: caption)  // label#2
        }
        tx.mountIn(1, auxRoot)
    }
}

app.run()
