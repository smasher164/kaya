// The stamped-accessibility scene from JS: two entries stamped from ONE
// template, each carrying its OWN ROW's accessibility identity, read back
// out of the PLATFORM'S accessibility tree (docs/tpl-props-plan.md P1).
//
// A SEPARATE SCENE BY DESIGN: a For materializes as a column, harness
// registries are creation-order, and container creation order differs by
// language — so the a11y scene, which asserts every container kind
// ordinally, cannot host a For. This scene asserts no container.
//
// Canonical note in guests/rust/a11yrows.rs; the byte-frozen contract is
// tools/scenes/a11yrows.steps.
//
// Build the library first (cargo build), then:
//     KAYA_SELFTEST=a11yrows node guests/js/a11yrows.ts

import * as kaya from "kaya-gui";

const app = new kaya.App();

app.window(() => {
  kaya.column(() => {
    // A SCALAR collection: an entry's value IS the note, so the loop
    // variable itself is what the props bind to.
    const notes = kaya.collection();
    for (const note of notes) {
      // THE ID MUST BE ELEMENT-SOURCED. expect_ax searches the real
      // tree by the AUTHORED identifier and refuses an ambiguous
      // one (docs/deferred.md), so copies cannot share a const id.
      kaya.entry().a11yId(note).a11yLabel(note);
    }
    notes.insertFresh("First note");
    notes.insertFresh("Second note");

    // THE STAMPED STYLING PROPS. A second collection because a scalar
    // row has one field to spend on an id, and expect_ax needs an
    // unambiguous one.
    //
    // BOTH PROPS ARE CONST, here and in every binding: what a copy
    // MEANS, and how far its prototype insets its children, are facts
    // about the PROTOTYPE and not the row (`accepts`'s rule).
    const heads = kaya.collection();
    for (const head of heads) {
      kaya.row({ inset: 8 }, () => {
        kaya.label({ bind: head }).role(kaya.Role.HEADING).a11yId(head);
      });
    }
    heads.insertFresh("Heading one");
    heads.insertFresh("Heading two");
  });
});

app.run();
