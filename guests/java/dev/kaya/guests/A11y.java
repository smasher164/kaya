package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The a11y scene from the JVM — guests/rust/a11y.rs, tools/scenes/a11y.steps.
 */
public final class A11y {
    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.mount(tx.column(() -> {
                // Deliberately not labelled: the platform must speak the caption.
                tx.button("Save").a11yId("save").a11yHint("save the draft");
                tx.checkbox("Details", null).a11yId("details")
                        .a11yHint("show more detail");
                tx.button("Reset").a11yId("reset");
                tx.label("Ready").a11yId("status");
                tx.entry().a11yId("name").a11yLabel("Full name");
                tx.textarea().a11yId("notes").a11yLabel("Notes");
                tx.slider(0.0, 1.0, 0.5, null).a11yId("volume").a11yLabel("Volume");
                tx.progress(0.25).a11yId("loading").a11yLabel("Loading");
                // Safe: the blob table holds its own reference by then.
                try (KayaApp.Asset mark = KayaApp.asset("images/a11y-logo.png")) {
                    tx.image(mark).a11yId("logo").a11yLabel("Logo");
                }
                tx.select(new String[] {"Red", "Green"}, 0, null)
                        .a11yId("color").a11yLabel("Color");
                tx.radio(new String[] {"Small", "Large"}, 0, null)
                        .a11yId("size").a11yLabel("Size");
                tx.grid(2, () -> {
                    tx.label("Name");
                    tx.label("Ada");
                }).a11yId("cells").a11yLabel("Cells");
                tx.scroll(() -> tx.label("Item")).a11yId("feed").a11yLabel("Feed");
                tx.row(() -> {
                    tx.button("Cancel").a11yId("cancel");
                    tx.button("OK").a11yId("ok");
                }).a11yId("actions").a11yLabel("Actions");
                KayaApp.Signal<String> spoken = tx.signal("Before");
                tx.label("Spoken").a11yId("spoken").a11yLabel(spoken);
                tx.button("Rename", inner -> inner.write(spoken, "After"))
                        .a11yId("rename");
            }).a11yId("form").a11yLabel("Form"));
            return null;
        });

        app.dispatchLoop();
    }
}
