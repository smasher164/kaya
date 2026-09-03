// The a11y conformance scene: exactly ONE container of each kind.
//     KAYA_SELFTEST=a11y node guests/js/a11y.ts

import * as kaya from "kaya-gui";

const app = new kaya.App();

app.window(() => {
  const form = kaya.column(() => {
    // Deliberately NOT labelled: the platform speaks the caption.
    kaya.button("Save").a11yId("save").a11yHint("save the draft");
    kaya.checkbox("Details").a11yId("details").a11yHint("show more detail");
    kaya.button("Reset").a11yId("reset");
    kaya.label("Ready").a11yId("status");
    kaya.entry().a11yId("name").a11yLabel("Full name");
    kaya.textarea().a11yId("notes").a11yLabel("Notes");
    kaya.slider({ min: 0, max: 1, value: 0.5 }).a11yId("volume").a11yLabel("Volume");
    kaya.progress({ value: 0.25 }).a11yId("loading").a11yLabel("Loading");
    // close() releases the core's handle once the blob table has it.
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
    const spoken = kaya.signal("Before");
    kaya.label("Spoken").a11yId("spoken").a11yLabel(spoken);
    kaya.button("Rename", { onClick: () => spoken.set("After") }).a11yId("rename");
  });
  form.a11yId("form").a11yLabel("Form");
});

app.run();
