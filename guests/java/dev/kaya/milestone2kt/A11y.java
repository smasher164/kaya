package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The accessibility conformance scene from the JVM: the two universal
 * props (a11yId, a11yLabel) and the verb that reads them back out of
 * the PLATFORM'S OWN accessibility tree rather than kaya's model.
 *
 * <p>Every widget kind appears, and exactly one container of each
 * container kind — the props are universal, and container targets are
 * stable only while a scene keeps one of each. See guests/rust/a11y.rs
 * for the full note; the byte-frozen contract is
 * tools/scenes/a11y.steps.
 */
final class A11y {
    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.mount(tx.column(() -> {
                // Caption-bearing controls: identified, but
                // deliberately NOT labelled. The platform must speak
                // the caption.
                tx.button("Save").a11yId("save").a11yHint("save the draft");
                tx.checkbox("Details", null).a11yId("details")
                        .a11yHint("show more detail");
                tx.button("Reset").a11yId("reset");
                tx.label("Ready").a11yId("status");
                // Caption-less controls: an app MUST name these, and
                // the tree must report the authored name.
                tx.entry().a11yId("name").a11yLabel("Full name");
                tx.textarea().a11yId("notes").a11yLabel("Notes");
                tx.slider(0.0, 1.0, 0.5, null).a11yId("volume").a11yLabel("Volume");
                tx.progress(0.25).a11yId("loading").a11yLabel("Loading");
                tx.image(TEST_PNG).a11yId("logo").a11yLabel("Logo");
                // The two CHOICE kinds: their options carry captions,
                // the choice itself does not.
                tx.select(new String[] {"Red", "Green"}, 0, null)
                        .a11yId("color").a11yLabel("Color");
                tx.radio(new String[] {"Small", "Large"}, 0, null)
                        .a11yId("size").a11yLabel("Size");
                // Containers are GROUPS to an assistive client, and
                // naming one is how an app declares it a group.
                tx.grid(2, () -> {
                    tx.label("Name");
                    tx.label("Ada");
                }).a11yId("cells").a11yLabel("Cells");
                tx.scroll(() -> tx.label("Item")).a11yId("feed").a11yLabel("Feed");
                tx.row(() -> {
                    tx.button("Cancel").a11yId("cancel");
                    tx.button("OK").a11yId("ok");
                }).a11yId("actions").a11yLabel("Actions");
            }).a11yId("form").a11yLabel("Form"));
            return null;
        });

        app.dispatchLoop();
    }

    /** A 2x2 RGB PNG (red/green over blue/white), 75 bytes: the gallery
     * scene's asset, embedded as source per the include_str! doctrine —
     * scenes carry their inputs, no runtime file I/O. */
    private static final byte[] TEST_PNG = {
        (byte) 137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
        0, 0, 0, 2, 0, 0, 0, 2, 8, 2, 0, 0, 0, (byte) 253, (byte) 212,
        (byte) 154, 115, 0, 0, 0, 18, 73, 68, 65, 84, 120, (byte) 156, 99,
        (byte) 248, (byte) 207, (byte) 192, (byte) 192, 0, (byte) 194, 12,
        (byte) 255, (byte) 129, 0, 0, 31, (byte) 238, 5, (byte) 251, 11,
        (byte) 217, 104, (byte) 139, 0, 0, 0, 0, 73, 69, 78, 68, (byte) 174,
        66, 96, (byte) 130,
    };
}
