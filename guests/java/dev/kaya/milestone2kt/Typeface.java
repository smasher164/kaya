package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The typeface conformance scene from the JVM (docs/styling-plan.md
 * Slice 2b): the brand typeface swaps the FAMILY and leaves the
 * platform's ramp alone. It names no size anywhere.
 *
 * <p>The scene ships the VENDORED font's bytes so the resolved family
 * is one string on every lane and no platform's fallback can equal it —
 * the reasoning is in guests/rust/typeface.rs. The byte-frozen contract
 * is tools/scenes/typeface.steps.
 */
final class Typeface {
    private static String draft = "";

    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
                        // BEFORE THE FIRST MOUNT, per the set-once wall. The bytes
                        // never enter this JVM's heap — the handle goes straight to
                        // the blob channel — and try-with-resources is safe because
                        // brandTypeface has already registered them into the pending
                        // blob table, which keeps its own reference.
            try (KayaApp.Asset font = KayaApp.asset("fonts/sora-wght.ttf")) {
                tx.brandTypeface("Sora", null, font);
            }
            tx.window(0).title("typeface").size(480.0, 360.0);
            KayaApp.Signal<String> heading = tx.signal("typeface");
            KayaApp.Signal<String> status = tx.signal("ready");

            tx.mount(tx.column(() -> {
                // The heading's text style OVERRIDES the root font, so
                // this label is the one a root-only lowering leaves in
                // the system face.
                tx.label(heading).role(KayaApp.Role.HEADING).a11yId("title"); // label#0
                tx.label(status); // label#1
                // A FIELD AND A TEXTAREA, because they take the swap by
                // DIFFERENT routes: the field inherits the root font,
                // the textarea names its own ramp rung. One of them
                // alone cannot tell a half-applied lowering from a
                // whole one.
                tx.entry((t, text) -> draft = text); // entry#0
                tx.textarea(); // textarea#0
                tx.button("Go", t -> t.write(status, "clicked " + draft)); // button#0
            }));
        });

        app.dispatchLoop();
    }

    private Typeface() {}
}
