// The commands scene, Swift port — guests/rust/commands.rs,
// tools/scenes/commands.steps.

import Foundation

let app = KayaApp()
var settingsCount = 0

app.build { tx in
    let status = tx.signal(.str("ready"))
    let details = tx.signal(.bool(false))
    let sort = tx.signal(.f64(0.0))

    // Reload keeps this menu non-empty once macOS moves Settings out.
    let file = tx.menu(
        "File",
        items: [
            tx.item("Reload"),
            tx.item("Settings…", shortcut: "primary+comma", role: KayaAppTx.roleSettings) { t in
                // Fires twice on purpose: the chord and the declared path.
                settingsCount += 1
                t.write(status, .str("settings \(settingsCount)"))
            },
        ])

    // Option order IS the index vocabulary: Name = 0, Date = 1.
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
