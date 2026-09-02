package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The accessibility conformance scene from the JVM: the two universal
 * props (a11yId, a11yLabel), read back out of the platform's own
 * accessibility tree. Exactly ONE container of each container kind:
 * container targets are ordinal. See guests/rust/a11y.rs;
 * tools/scenes/a11y.steps.
 */
final class A11y {
    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.mount(tx.column(() -> {
                // Caption-bearing controls: deliberately NOT labelled,
                // so the platform has to speak the caption.
                tx.button("Save").a11yId("save").a11yHint("save the draft");
                tx.checkbox("Details", null).a11yId("details")
                        .a11yHint("show more detail");
                tx.button("Reset").a11yId("reset");
                tx.label("Ready").a11yId("status");
                // Caption-less controls: an app MUST name these.
                tx.entry().a11yId("name").a11yLabel("Full name");
                tx.textarea().a11yId("notes").a11yLabel("Notes");
                tx.slider(0.0, 1.0, 0.5, null).a11yId("volume").a11yLabel("Volume");
                tx.progress(0.25).a11yId("loading").a11yLabel("Loading");
                // THE MARK THE APP'S OWN BUILD SHIPPED: the bytes never
                // enter this JVM's heap, and try-with-resources is safe
                // because the blob table already holds its own
                // reference.
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
                // A spoken name that FOLLOWS A SIGNAL: the live trio's
                // Signal overloads, the template zone's shape live.
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
