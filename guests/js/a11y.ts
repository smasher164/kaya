// The accessibility conformance scene from JS: the two universal props
// (a11yId, a11yLabel), read back out of the PLATFORM'S OWN accessibility
// tree rather than kaya's model.
//
// Every widget kind appears, and exactly one container of each container
// kind — container targets are ordinal. See guests/rust/a11y.rs; the
// byte-frozen contract is tools/scenes/a11y.steps.
//
// Build the library first (cargo build), then:
//     KAYA_SELFTEST=a11y node guests/js/a11y.ts

import * as kaya from "kaya-gui";

const app = new kaya.App();

app.window(() => {
  const form = kaya.column(() => {
    // Caption-bearing controls: identified, deliberately NOT labelled
    // — the platform must speak the caption.
    kaya.button("Save").a11yId("save").a11yHint("save the draft");
    kaya.checkbox("Details").a11yId("details").a11yHint("show more detail");
    kaya.button("Reset").a11yId("reset");
    kaya.label("Ready").a11yId("status");
    // Caption-less controls: an app MUST name these, and the tree
    // must report the authored name.
    kaya.entry().a11yId("name").a11yLabel("Full name");
    kaya.textarea().a11yId("notes").a11yLabel("Notes");
    kaya.slider({ min: 0, max: 1, value: 0.5 }).a11yId("volume").a11yLabel("Volume");
    kaya.progress({ value: 0.25 }).a11yId("loading").a11yLabel("Loading");
    // THE MARK THE APP'S OWN BUILD SHIPPED: the bytes never enter JS,
    // and the close() releases the core's handle once the blob table
    // holds its own reference.
    const logo = kaya.asset("images/a11y-logo.png");
    kaya.image(logo).a11yId("logo").a11yLabel("Logo");
    logo.close();
    kaya.select(["Red", "Green"]).a11yId("color").a11yLabel("Color");
    kaya.radio(["Small", "Large"]).a11yId("size").a11yLabel("Size");
    const cells = kaya.grid(2, () => {
      kaya.label("Name");
      kaya.label("Ada");
    });
    cells.a11yId("cells").a11yLabel("Cells");
    const feed = kaya.scroll(() => {
      kaya.label("Item");
    });
    feed.a11yId("feed").a11yLabel("Feed");
    const actions = kaya.row(() => {
      kaya.button("Cancel").a11yId("cancel");
      kaya.button("OK").a11yId("ok");
    });
    actions.a11yId("actions").a11yLabel("Actions");
    // A spoken name that FOLLOWS A SIGNAL: the surface JS had from its
    // first day, uniform across the nine since 2026-09-02.
    const spoken = kaya.signal("Before");
    kaya.label("Spoken").a11yId("spoken").a11yLabel(spoken);
    kaya.button("Rename", { onClick: () => spoken.set("After") }).a11yId("rename");
  });
  form.a11yId("form").a11yLabel("Form");
});

app.run();
