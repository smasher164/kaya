// The typeface conformance scene, JS port (docs/styling-plan.md Slice
// 2b): the brand typeface swaps the FAMILY and leaves the platform's
// ramp alone.
//
// The scene names NO SIZE anywhere: sizes, weights and metrics stay the
// platform's, and the role tier carries emphasis (`Role.HEADING` on the
// title label below).
//
// WHY A BUNDLED FONT — the canonical note is guests/rust/typeface.rs's doc
// comment. `font` is JS's spelling of the blob form; `platforms` is the
// per-platform mapping a name-based app would reach for instead.
//
// THE FONT IS AN ASSET (docs/assets-plan.md, ratified 2026-08-18):
// `kaya.asset(name)` is the whole thing — where the file lives is the
// core's knowledge, and the failure sentence has one author.
//
// The byte-frozen contract is tools/scenes/typeface.steps.

import * as kaya from "kaya-gui";

const app = new kaya.App();

let draft = "";

function onChange(text: string): void {
  // The fold: widget-owned state arrives as occurrences, and the app's
  // copy is this variable rather than a widget read.
  draft = text;
}

function onGo(): void {
  status.set(`clicked ${draft}`);
}

let status!: kaya.Signal<string>;

app.window({ title: "typeface", width: 480, height: 360 }, () => {
  // BEFORE THE FIRST MOUNT, per the set-once wall. The scope mounts on
  // exit, so anywhere in this body is before it. The blob registers
  // with the platform's app-font machinery and the "Sora" request then
  // resolves to it; close() releases the core's handle.
  const font = kaya.asset("fonts/sora-wght.ttf");
  kaya.brandTypeface("Sora", { font });
  font.close();
  const heading = kaya.signal("typeface");
  status = kaya.signal("ready");
  kaya.column(() => {
    // The heading's text style OVERRIDES the root font, so this label
    // is the one a root-only lowering leaves in the system face;
    // expect_ax resolves it through its authored id.
    kaya.label({ bind: heading }).role(kaya.Role.HEADING).a11yId("title"); // label#0
    kaya.label({ bind: status }); // label#1
    // Both a field and a textarea: they take the swap by DIFFERENT
    // routes (the field inherits the root font, the textarea names its
    // own ramp rung), so one alone could not tell a half-applied
    // lowering from a whole one.
    kaya.entry({ onChange }); // entry#0
    kaya.textarea(); // textarea#0
    kaya.button("Go", { onClick: onGo }); // button#0
  });
});

app.run();
