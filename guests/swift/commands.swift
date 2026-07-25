// The standard-commands scene, Swift port: a chord on every leaf kind
// (a checkable command, one option of a group, a plain command), the
// punctuation keys those chords need, and the `settings` role — which
// macOS shows in the application menu while the item stays addressable
// where it was declared. Canonical semantics in
// guests/rust/commands.swift's Rust sibling (guests/rust/commands.rs);
// the byte-frozen contract in tools/scenes/commands.steps.

import Foundation

let app = KayaApp()
var settingsCount = 0

app.build { tx in
    let status = tx.signal(.str("ready"))
    let details = tx.signal(.bool(false))
    let sort = tx.signal(.f64(0.0))

    // The settings command declares its own punctuation chord and the
    // role that tells macOS where users look for it. An ordinary
    // command sits beside it so the menu that declared it is not left
    // empty once the platform moves it.
    let file = tx.menu(
        "File",
        items: [
            tx.item("Reload"),
            tx.item("Settings…", shortcut: "primary+comma", role: KayaAppTx.roleSettings) { t in
                // Fires twice on purpose: once by the chord, once by
                // activating the item at its DECLARED path — which on
                // macOS lives in the application menu by then.
                settingsCount += 1
                t.write(status, .str("settings \(settingsCount)"))
            },
        ])

    // A checkable command carrying its own key, and a group whose
    // options each answer their own chord. Option order IS the index
    // vocabulary: Name = 0, Date = 1.
    let view = tx.menu(
        "View",
        items: [
            tx.toggle("Details", checked: details, shortcut: "primary+backslash") { t, on in
                t.write(status, .str(on ? "details on" : "details off"))
            },
            tx.radioGroup(
                "Sort",
                options: [
                    tx.option("Name", shortcut: "primary+1"),
                    tx.option("Date", shortcut: "primary+2"),
                ], value: sort
            ) { t, index in
                t.write(status, .str(index == 1 ? "sorted date" : "sorted name"))
            },
        ])
    tx.window(title: "commands", menus: [file, view])

    let root = tx.column {
        tx.label(bind: status)  // label#0
    }
    tx.mount(root)
}

app.run()
