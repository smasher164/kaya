// The app-identity conformance scene, Swift port — see
// guests/rust/identity.rs for the canonical note. An app declares what
// it is called and what it looks like, and the platform shows both. The
// byte-frozen contract is tools/scenes/identity.steps.
//
// THE MARK IS THE VENDORED ONE (four flat quadrants) because no
// platform's own default icon can land on four declared colours, so a
// lowering that never applied can never read as a pass. It is an ASSET:
// this source serves mac AND iOS, and the bundle's Resources is exactly
// the place a repo-relative path could not name.
//
// THE SECOND WINDOW HAS NO TITLE OF ITS OWN, deliberately: that is the
// blank an app's NAME fills on every platform.

import Foundation

let app = KayaApp()

var status: KayaSignal!

// The fold: widget-owned state arrives as occurrences.
var draft = ""

try app.build { tx in
        // BEFORE THE FIRST MOUNT, per the declared-once wall. The bytes
        // never enter this guest's heap — the handle goes straight to the
        // blob channel — and the release is explicit, safe because
        // appIdentity has already registered them into the pending blob
        // table, which keeps its own reference.
        //
        // `try` AND NO `catch`: a mark the build did not ship is a wall at
        // startup, and an app with no icon is not a thing this scene knows
        // how to be. The throw carries the core's sentence out through
        // `build` — which rolls the transaction back — and off the top of
        // the program. The assets scene is where the catch is exercised.
    let icon = try KayaAsset("icons/kaya-mark.png")
    tx.appIdentity("Aurora Notes", icon: icon)
    icon.close()

    // ONE PROMOTED COMMAND, AND IT IS NOT ABOUT COMMANDS. Windows mints
    // its custom caption from the first promotion and from nothing else,
    // and a custom caption REPLACES the system one — taking the
    // system-drawn app icon with it. That is why the identity has a
    // second Windows sink at all, and a scene with no promotion anywhere
    // would leave that sink's arm unreached.
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

        // THE UNTITLED WINDOW, and it is DESKTOP-ONLY: iOS's system owns
        // surface geometry, so KAYA_CAP_AUX_WINDOWS is unset there and
        // `createWindow` is a deterministic scene error — a guest that built
        // it would abort before it ever mounted, with the identity already
        // declared. The iOS leg drops the one step that reads this window;
        // the NAME's reader there is the bundle's own display name
        // (docs/app-identity-plan.md ruling 3). It declares no title at all
        // rather than an empty one: an empty string is a title an app WROTE,
        // and the rule under test is what a window with nothing written
        // shows.
        //
        // THE HOST IS ASKED, not the platform. `KayaApp.capabilities()`
        // reads the core's own word (crates/kaya/src/scene.rs's
        // CAPABILITIES), which is the same const the wall inside
        // `createWindow` tests. ONE SOURCE SERVES MAC AND iOS, so a runtime
        // `if` is also the only spelling that can be read once and mean
        // both. (A `#if` around an IMPORT or an unavailable API is a
        // different thing and stays: that one exists so the file compiles at
        // all, not so a call is skipped.)
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
