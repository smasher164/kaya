// The stamped-a11y scene: it asserts NO container, because a For is one.
//     KAYA_SELFTEST=a11yrows node guests/js/a11yrows.ts

import * as kaya from "kaya-gui";

const app = new kaya.App();

app.window(() => {
  kaya.column(() => {
    // A SCALAR collection: the loop variable IS the element.
    const notes = kaya.collection();
    for (const note of notes) {
      // expect_ax REFUSES copies that share one const id.
      kaya.entry().a11yId(note).a11yLabel(note);
    }
    notes.insertFresh("First note");
    notes.insertFresh("Second note");

    // A SECOND collection: a scalar row has one field for an id, and both
    // props below are CONST in every binding.
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
