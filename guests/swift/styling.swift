// The styling conformance scene, Swift port — see guests/rust/styling.rs
// for the full rationale. The brand accent, the role tier and the window
// inset in one scene, because they are one design (docs/styling-plan.md
// slice 1): brand slots fill each platform's token system, roles say
// what a widget MEANS, and the inset is the one layout knob the pass
// admitted.
//
// What each piece demonstrates:
//   - `brandAccent(0x3584E4)` — Adwaita blue, the derivation's empirical
//     anchor: one hex is the whole call, the core derives fills and
//     foregrounds, and a platform may let its user override the result
//     (D2 — on macOS an app accent applies only while the system accent
//     is multicolor).
//   - `role: .heading` on the title label — the platform's heading text
//     style AND the assistive heading trait, which is the one role the
//     steps freeze from the real tree on every lane.
//   - `role: .destructive` / `role: .prominent` on the two buttons — the
//     platform's own emphasis chrome, and (the scene's point) NO change
//     to what pressing them does.
//   - `inset: 0` — full bleed, the editor's own need, honored
//     unconditionally because the inset is kaya's padding (D3).
//
// The byte-frozen contract is tools/scenes/styling.steps.

import Foundation

let app = KayaApp()

var status: KayaSignal!

app.build { tx in
    // BEFORE THE FIRST MOUNT, per the set-once wall: brand is identity,
    // not state.
    tx.brandAccent(0x3584E4)
    tx.window(title: "styling", width: 480, height: 360, inset: 0)

    let heading = tx.signal(.str("Sections"))
    status = tx.signal(.str("ready"))
    let root = tx.column {
        // expect_ax resolves a target through its AUTHORED id into the
        // real tree, so everything the steps read back is identified
        // (the a11y scene's discipline).
        let title = tx.label(bind: heading, role: .heading)  // label#0
        tx.setA11yId(title, "title")
        tx.label(bind: status)  // label#1
        let delete = tx.button("Delete", role: .destructive) { tx in  // button#0
            tx.write(status, .str("deleted"))
        }
        tx.setA11yId(delete, "delete")
        let save = tx.button("Save", role: .prominent) { tx in  // button#1
            tx.write(status, .str("saved"))
        }
        tx.setA11yId(save, "save")
    }
    tx.mount(root)
}

app.run()
