// The stamped-accessibility scene from Swift: two entries stamped from
// ONE template, each carrying its OWN ROW's accessibility identity, read
// back out of the platform's real tree. The a11y scene proves the
// wrap-native bet for LIVE widgets; this one proves it for COPIES — the
// case none of the accessibility milestone's 719 legs ever exercised,
// because until the template zone could spell the props
// (docs/tpl-props-plan.md P1) no guest could name a stamped widget at
// all.
//
// A SEPARATE SCENE BY DESIGN, not by size: a For materializes as a
// column, harness registries are creation-order, and container creation
// order differs by language — so the a11y scene, which asserts every
// container kind ordinally, cannot host a For without `column#0` meaning
// different widgets on different lanes. This scene asserts no container,
// so the For's column may land anywhere in the registry
// (guests/haskell/reorder.hs documents the ordering rule).
//
// See guests/rust/a11yrows.rs for the canonical semantics; the
// byte-frozen contract is tools/scenes/a11yrows.steps.

import Foundation

let app = KayaApp()

app.build { tx in
    let notes = tx.collection()
    let root = tx.column {
        tx.each(notes) { t in
            // BOTH PROPS ELEMENT-SOURCED. The label is the point — a
            // list row announcing its own name to assistive tech. The id
            // is forced: expect_ax searches the real tree BY the
            // authored identifier, so copies sharing a const id are
            // indistinguishable to it and the read refuses them (it
            // answered with the first copy's label for the second's
            // index until it learned to). A shared const id stays legal
            // in the core; it is just unreadable by that verb.
            //
            // `.element` is the scalar collection's own token: its
            // element IS the value, so there is no field name to give.
            let field = t.entry()  // entry#0 and entry#1 once the rows stamp
            t.setA11yId(field, KayaField<String>.element)
            t.setA11yLabel(field, KayaField<String>.element)
        }
    }
    // OUTSIDE THE BUILDER, BEFORE THE MOUNT. An insert is not a child,
    // so it has no place among the container's declarations; putting it
    // ahead of the mount keeps this guest's op order identical to
    // guests/rust/a11yrows.rs, which is the order the scene was first
    // read against. Seeding after the mount also stamps (reorder.swift
    // does it), so this is the difference that has no upside rather than
    // a rule.
    //
    // A note is a line of text with no identity of its own, so the key
    // comes from the minter rather than from a name this scene would
    // have to invent; nothing here reads the minted key back, which is
    // what @discardableResult permits.
    tx.insertFresh(notes, .str("First note"))
    tx.insertFresh(notes, .str("Second note"))
    tx.mount(root)
}

app.run()
